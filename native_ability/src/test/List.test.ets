import localUnitTest from "./LocalUnit.test";
import keySynthesisTest from "./KeySynthesis.test";

export default function testsuite() {
  localUnitTest();
  keySynthesisTest();
}
