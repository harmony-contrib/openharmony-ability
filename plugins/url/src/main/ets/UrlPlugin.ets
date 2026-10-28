import {
  BridgeCallContext,
  BridgeTypedValue,
  AsyncPluginBase,
  BridgeContextRequirement,
} from "@ohos-rs/ability";
import Want from "@ohos.app.ability.Want";

const OPEN_REQUEST_TYPE = "ohos.url.OpenRequest";
const REVEAL_REQUEST_TYPE = "ohos.url.RevealRequest";
const OPEN_RESPONSE_TYPE = "ohos.url.OpenResponse";

interface UrlOpenRequest {
  url: string;
}

interface UrlRevealRequest {
  path: string;
}

// Public-directory path forms an app may hold, all mapping into the
// file-manager virtual uri `file://docs/storage/Users/currentUser/<Virtual>`:
//  - /storage/media/100/local/files/<top>   (global real path, shell view)
//  - /storage/Users/currentUser/files/<top> (per-account hmdfs mount view)
//  - /storage/Users/currentUser/<Virtual>   (file-manager virtual form)
// None of these are stat-able from a normal app sandbox (not mounted /
// hmmac-restricted), so paths may arrive unvalidated from the Rust side —
// the file manager is the final arbiter of what it opens.
const PUBLIC_BASE_PREFIXES: ReadonlyArray<string> = [
  "/storage/media/100/local/files/",
  "/storage/users/currentuser/files/",
  "/storage/users/currentuser/",
];

// Real top-level directory name (lowercase) → file-manager virtual name.
// All 6 virtual names verified on 2in1 desktop (2026-08-28 device experiment via
// `aa start` + hilog setCurrentUri): FM accepts EXACTLY {Documents, Download,
// Desktop, Images, Videos, Music} — a fixed internal set unrelated to the real
// filesystem dir names. "Images" (not "Pictures") is the picture virtual name;
// "Music" (not "Audio") is the audio virtual name. Real dirs with no matching
// virtual name (Photo, Camera, Audios) fall through to the documented
// "no mapping" error below (honest rejection, never a silent wrong-folder open).
interface PublicDirEntry {
  realName: string;
  virtualName: string;
  verified: boolean;
}

const TOP_DIR_TO_VIRTUAL: ReadonlyArray<PublicDirEntry> = [
  { realName: "docs", virtualName: "Documents", verified: true },
  // "documents" is not a real fs dir (real name is "Docs"), but a user may type
  // it in the reveal path input; Documents is a valid virtual name, so accept it.
  { realName: "documents", virtualName: "Documents", verified: true },
  { realName: "desktop", virtualName: "Desktop", verified: true },
  { realName: "download", virtualName: "Download", verified: true },
  { realName: "pictures", virtualName: "Images", verified: true },
  { realName: "music", virtualName: "Music", verified: true },
  // Real "Audio"/"Audios" dirs map to the "Music" virtual name (Audio virtual
  // name is rejected by FM; "Music" opens the 音频 folder which holds audio).
  { realName: "audio", virtualName: "Music", verified: true },
  { realName: "audios", virtualName: "Music", verified: true },
  { realName: "videos", virtualName: "Videos", verified: true },
];

// App-sandbox path markers: the file manager can never open these (platform
// limitation), so they are rejected with a documented error instead of a
// silent fallback to the notepad handler.
const SANDBOX_MARKERS: ReadonlyArray<string> = ["/data/storage/", "/data/app/"];

class UrlOpenResponse {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

function parseOpenRequest(payload: BridgeTypedValue): UrlOpenRequest {
  if (payload.typeName !== OPEN_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.url.open-url requires bridge type ${OPEN_REQUEST_TYPE}`);
  }
  const request = payload.value as UrlOpenRequest;
  if (typeof request.url !== "string" || !request.url.trim() || request.url.indexOf("://") < 0) {
    throw new Error("open-url.url must be an absolute URL with a scheme");
  }
  return request;
}

function parseRevealRequest(payload: BridgeTypedValue): UrlRevealRequest {
  if (payload.typeName !== REVEAL_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.url.reveal-in-dir requires bridge type ${REVEAL_REQUEST_TYPE}`);
  }
  const request = payload.value as UrlRevealRequest;
  if (typeof request.path !== "string" || !request.path.trim()) {
    throw new Error("reveal-in-dir.path must be a non-empty string");
  }
  return request;
}

function isSandboxPath(p: string): boolean {
  const lower = p.toLowerCase();
  for (const marker of SANDBOX_MARKERS) {
    if (lower.startsWith(marker) || lower.includes(marker)) {
      return true;
    }
  }
  return false;
}

/**
 * Maps a real filesystem parent-directory path to the file-manager Want uri:
 *   file://docs/storage/Users/currentUser/<virtualName>[/<subPath>]
 * Accepts the shell-real, hmdfs-mount, and virtual path forms (see
 * PUBLIC_BASE_PREFIXES). Sandbox paths and unmappable prefixes throw a
 * documented error (never a silent fallback to the notepad default handler).
 */
function mapToVirtualUri(realPath: string): string {
  const trimmedPath = realPath.replace(/\/+$/, "");
  const lower = trimmedPath.toLowerCase();

  if (isSandboxPath(realPath)) {
    throw new Error(
      `[reveal-in-dir] OHOS file manager cannot open app-sandbox paths (${realPath}). ` +
        `Reveal only works for public directories (e.g. /storage/media/100/local/files/Docs/...). ` +
        `This is a platform limitation.`,
    );
  }

  let base: string | undefined;
  for (const candidate of PUBLIC_BASE_PREFIXES) {
    if (lower === candidate.slice(0, -1) || lower.startsWith(candidate)) {
      base = candidate;
      break;
    }
  }
  if (!base) {
    throw new Error(
      `[reveal-in-dir] path is not under a mappable public directory (${realPath}). ` +
        `Mappable bases: ${PUBLIC_BASE_PREFIXES.join(", ")} followed by a known top-level ` +
        `directory (docs, desktop, download, pictures, music, videos). ` +
        `Only Docs→Documents is verified on 2in1 desktop; others are unverified.`,
    );
  }

  const topSegment = lower.slice(base.length).split("/")[0];
  let matched: PublicDirEntry | undefined;
  for (const entry of TOP_DIR_TO_VIRTUAL) {
    if (entry.realName === topSegment) {
      matched = entry;
      break;
    }
  }
  if (!matched) {
    throw new Error(
      `[reveal-in-dir] top-level directory "${topSegment}" has no file-manager virtual ` +
        `name mapping (${realPath}). Known top-level names: docs, desktop, download, ` +
        `pictures, music, videos. Only Docs→Documents is verified on 2in1 desktop.`,
    );
  }

  // The sub-path keeps the original casing; slice indices align because `lower`
  // differs from `trimmedPath` only by case.
  const subPath = trimmedPath.slice(base.length + topSegment.length).replace(/^\/+/, "");
  return subPath.length > 0
    ? `file://docs/storage/Users/currentUser/${matched.virtualName}/${subPath}`
    : `file://docs/storage/Users/currentUser/${matched.virtualName}`;
}

export class UrlPlugin extends AsyncPluginBase {
  readonly id = "ohos.url";
  readonly requires: BridgeContextRequirement[] = ["ability"];

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (action === "open-url") {
      const request = parseOpenRequest(payload);
      try {
        await context.abilityContext.openLink(request.url);
      } catch (error) {
        throw new Error(`openLink failed: ${String(error)}`);
      }
      if (!context.isActive()) {
        throw new Error("Ability was destroyed while the URL was being opened");
      }
      return { typeName: OPEN_RESPONSE_TYPE, value: new UrlOpenResponse(true) };
    }

    if (action === "reveal-in-dir") {
      const request = parseRevealRequest(payload);
      // Map the real filesystem parent path to the file-manager virtual uri and
      // start an EXPLICIT Want — the only form empirically verified to reach the
      // 2in1 desktop file manager (com.huawei.hmos.filemanager / MainAbility /
      // module "pc"). A generic viewData+file:// want only matches archive utd
      // types and silently falls back to the notepad handler.
      // Sandbox/unmappable-prefix paths throw before startAbility, so they can
      // never fall through to a wrong handler.
      // No fallback is attempted: on systems without the Huawei file manager
      // (non-Huawei environments, or a package rename) startAbility throws and
      // the error below is propagated to the caller. The OHOS SDK (checked
      // against 6.1.1 / API 24) exposes no system-generic "reveal in folder"
      // API — the HMS filePreview kit is content preview only — so this
      // explicit Want is the only workable form.
      //
      // ⚠️ Want parameter placement (2026-08-28 device experiment): FM MainAbility
      // reads the target from `want.parameters.fileUri` + `want.parameters.external_storage_uuid`,
      // NOT from `want.uri` (top-level `uri` is ignored → FM defaults to home).
      // `external_storage_uuid = "LOCAL"` is the local disk id (verified via FM
      // diskNameArray; cloud = "cloud").
      const want: Want = {
        bundleName: "com.huawei.hmos.filemanager",
        abilityName: "MainAbility",
        moduleName: "pc",
        parameters: {
          fileUri: mapToVirtualUri(request.path),
          external_storage_uuid: "LOCAL",
        },
      };
      try {
        await context.abilityContext.startAbility(want);
      } catch (error) {
        throw new Error(`reveal-in-dir startAbility failed: ${String(error)}`);
      }
      if (!context.isActive()) {
        throw new Error("Ability was destroyed while the directory was being revealed");
      }
      return { typeName: OPEN_RESPONSE_TYPE, value: new UrlOpenResponse(true) };
    }

    throw new Error(`Unsupported ohos.url action '${action}'`);
  }
}
