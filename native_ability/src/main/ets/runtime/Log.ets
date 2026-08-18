import hilog from "@ohos.hilog";

const DOMAIN = 0x52aa;
const TAG = "ohos-rs-ability";

/**
 * Framework logger backed by hilog. The framework never drops an operational error silently:
 * failures that applications cannot observe through a rejected Promise are reported here.
 */
export class Log {
  static error(message: string): void {
    hilog.error(DOMAIN, TAG, "%{public}s", message);
  }

  static warn(message: string): void {
    hilog.warn(DOMAIN, TAG, "%{public}s", message);
  }

  static info(message: string): void {
    hilog.info(DOMAIN, TAG, "%{public}s", message);
  }
}
