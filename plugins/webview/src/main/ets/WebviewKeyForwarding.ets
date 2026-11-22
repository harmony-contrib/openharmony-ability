export const NATIVE_KEY_EVENT_TYPE = "ohos.webview.NativeKeyEvent";
export const NATIVE_KEY_PROXY_NAME = "__abilityNativeKey";

export const NATIVE_KEY_INIT_SCRIPT: string = [
  "(function(){",
  "if(window.__abilityKeyInstalled)return;",
  "window.__abilityKeyInstalled=true;",
  "var M={Shift:1,Control:1,Alt:1,AltGraph:1,Meta:1,OS:1,Super:1,Hyper:1,Fn:1,FnLock:1,CapsLock:1,NumLock:1,ScrollLock:1,Symbol:1,SymbolLock:1};",
  "var V={ArrowUp:1,ArrowDown:1,ArrowLeft:1,ArrowRight:1,Home:1,End:1,PageUp:1,PageDown:1};",
  "var E={65:1,67:1,86:1,88:1,89:1,90:1};",
  "var NT={button:1,checkbox:1,color:1,file:1,hidden:1,image:1,radio:1,range:1,reset:1,submit:1};",
  'var CT=\'a[href],area[href],button,summary,input,[role="button"],[role="link"],[role="checkbox"],[role="tab"]\';',
  'var AD=\'input[type="range"],input[type="radio"],audio[controls],video[controls],[role="slider"],[role="radiogroup"]\';',
  'var FQ=\'a[href],area[href],button:not([disabled]),input:not([disabled]):not([type="hidden"]),select:not([disabled]),textarea:not([disabled]),summary,iframe,[tabindex]:not([tabindex="-1"]),[contenteditable]:not([contenteditable="false"])\';',
  "var pr=null;",
  "addEventListener('pointerdown',function(e){var p=e.composedPath?e.composedPath()[0]:e.target;pr=p instanceof Element?p:null;},true);",
  "function tg(el){if(!el)return'other';if(el.isContentEditable||el instanceof HTMLTextAreaElement||el instanceof HTMLSelectElement)return'text';if(el instanceof HTMLInputElement&&!NT[el.type])return'text';return el.closest(AD)?'adjustable':el.closest(CT)?'control':'other';}",
  "function sd(e){if(e.altKey||e.metaKey)return null;if(e.ctrlKey)return e.key==='Home'?'up':e.key==='End'?'down':null;switch(e.key){case 'ArrowUp':case 'PageUp':case 'Home':return 'up';case 'ArrowDown':case 'PageDown':case 'End':return 'down';case 'ArrowLeft':return 'left';case 'ArrowRight':return 'right';case ' ':return e.shiftKey?'up':'down';}return null;}",
  "function rm(n,d){if(d==='up')return n.scrollTop>0;if(d==='down')return n.scrollTop+n.clientHeight<n.scrollHeight-1;return n.scrollWidth>n.clientWidth+1;}",
  "function sc(f,d){var rt=document.scrollingElement;for(var n=f;n&&n!==rt&&n!==document.body;){var st=getComputedStyle(n);var ov=(d==='up'||d==='down')?st.overflowY:st.overflowX;if((ov==='auto'||ov==='scroll'||ov==='overlay')&&rm(n,d))return true;n=n.parentElement||(n.getRootNode&&n.getRootNode().host)||null;}if(!rt||!rm(rt,d))return false;var hd=function(el){return !!el&&getComputedStyle(el)[(d==='up'||d==='down')?'overflowY':'overflowX']==='hidden';};return !hd(document.documentElement)&&!hd(document.body);}",
  "function md(){if(document.fullscreenElement)return true;var q=document.querySelectorAll('[aria-modal=\"true\"],dialog[open]');return q.length>0;}",
  "function fw(e,t,s,m){if((e.isComposing||e.keyCode===229)||(e.getModifierState&&e.getModifierState('AltGraph'))||e.key==='Tab'||e.key==='Dead'||e.key==='Process'||M[e.key])return false;if(e.key==='Escape')return !m;if(/^F\\d+$/.test(e.key))return true;var ch=(e.ctrlKey||e.metaKey)&&!(e.ctrlKey&&e.altKey);if(ch&&E[e.keyCode])return false;if(t==='text')return ch&&!V[e.key]&&e.key!=='Backspace'&&e.key!=='Delete'&&e.key!=='Insert';if(t!=='other'&&!ch&&!e.altKey&&(e.key==='Enter'||e.key===' '))return false;if(t==='adjustable'&&!ch&&!e.altKey&&V[e.key])return false;var d=sd(e);return !d||!s(d);}",
  "addEventListener('keydown',function(e){if(!e.isTrusted||e.defaultPrevented||!window.__abilityNativeKey)return;",
  "var el=e.composedPath?e.composedPath()[0]:document.activeElement;if(!(el instanceof Element))el=document.activeElement;for(var a=el&&el.shadowRoot&&el.shadowRoot.activeElement;a;a=a.shadowRoot&&a.shadowRoot.activeElement)el=a;",
  "if(e.key==='Tab'&&!e.ctrlKey&&!e.altKey&&!e.metaKey&&!e.isComposing){var all=Array.prototype.slice.call(document.querySelectorAll(FQ)).filter(function(n){return n.offsetWidth>0||n.offsetHeight>0||n.getClientRects().length>0;});var idx=el?all.indexOf(el):-1;if(all.length===0||(e.shiftKey?idx<=0:(idx===-1||idx>=all.length-1))){e.preventDefault();e.stopPropagation();window.__abilityNativeKey.onTabOut(!!e.shiftKey);}return;}",
  "if(el===document.body||el===document.documentElement)el=null;var from=el||pr;if(!fw(e,tg(el),function(d){return sc(from,d);},md()))return;",
  "var k=e.key||'',c=e.code||'',kc=e.keyCode||0,sh=!!e.shiftKey,ct=!!e.ctrlKey,al=!!e.altKey,mt=!!e.metaKey,rp=!!e.repeat;",
  "setTimeout(function(){if(!e.defaultPrevented&&window.__abilityNativeKey)window.__abilityNativeKey.onKey(k,c,kc,sh,ct,al,mt,rp);},0);},false);",
  "})();",
].join("\n");

export function shouldForwardWebviewKeys(
  eventKeyEnabled: boolean | null | undefined,
  nativeForwardKeys: boolean | null | undefined,
): boolean {
  return eventKeyEnabled === true || nativeForwardKeys === true;
}

export class WebviewNativeKeyEventPayload {
  readonly id: string;
  readonly nativeTag: string;
  readonly targetId: number;
  readonly kind: string;
  readonly key: string;
  readonly code: string;
  readonly keyCode: number;
  readonly shift: boolean;
  readonly ctrl: boolean;
  readonly alt: boolean;
  readonly meta: boolean;
  readonly repeat: boolean;

  constructor(
    id: string,
    nativeTag: string,
    targetId: number,
    kind: string,
    key: string,
    code: string,
    keyCode: number,
    shift: boolean,
    ctrl: boolean,
    alt: boolean,
    meta: boolean,
    repeat: boolean,
  ) {
    this.id = id;
    this.nativeTag = nativeTag;
    this.targetId = targetId;
    this.kind = kind;
    this.key = key;
    this.code = code;
    this.keyCode = keyCode;
    this.shift = shift;
    this.ctrl = ctrl;
    this.alt = alt;
    this.meta = meta;
    this.repeat = repeat;
  }
}

export type NativeKeyDispatchFn = (
  kind: string,
  key: string,
  code: string,
  keyCode: number,
  shift: boolean,
  ctrl: boolean,
  alt: boolean,
  meta: boolean,
  repeat: boolean,
) => void;

export class NativeKeyJsProxy {
  private readonly dispatch: NativeKeyDispatchFn;

  constructor(dispatch: NativeKeyDispatchFn) {
    this.dispatch = dispatch;
  }

  onTabOut(shift: boolean): void {
    this.dispatch("tab-out", "Tab", "Tab", 9, Boolean(shift), false, false, false, false);
  }

  onKey(
    key: string,
    code: string,
    keyCode: number,
    shift: boolean,
    ctrl: boolean,
    alt: boolean,
    meta: boolean,
    repeat: boolean,
  ): void {
    this.dispatch(
      "key",
      typeof key === "string" ? key : "",
      typeof code === "string" ? code : "",
      Number.isFinite(keyCode) ? Math.trunc(keyCode) : 0,
      Boolean(shift),
      Boolean(ctrl),
      Boolean(alt),
      Boolean(meta),
      Boolean(repeat),
    );
  }
}
