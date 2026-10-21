/** Native edit counts prevent delayed controlled values from replacing newer IME input. */
export class ControlledText {
  text: string;
  count: number;
  constructor(text: string, count: number) {
    this.text = text;
    this.count = count;
  }
  update(text: string, count: number): void {
    if (count === this.count) {
      this.text = text;
    }
  }
  change(text: string): boolean {
    if (text === this.text) {
      return false;
    }
    this.text = text;
    this.count = (this.count + 1) >>> 0;
    return true;
  }
}
