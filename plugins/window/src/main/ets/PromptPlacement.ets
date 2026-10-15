export interface PromptOffset {
  dx: number;
  dy: number;
}

/** All dimensions are vp in the target window's content coordinate system. */
export class PromptPlacement {
  readonly viewportWidth: number;
  readonly viewportHeight: number;
  readonly width: number;
  readonly maxHeight: number;

  constructor(viewportWidth: number, viewportHeight: number, anchored: boolean) {
    this.viewportWidth = viewportWidth;
    this.viewportHeight = viewportHeight;
    this.width = Math.min(anchored ? 240 : 400, Math.max(1, viewportWidth * 0.9));
    this.maxHeight = Math.max(1, viewportHeight * 0.9);
  }

  offset(x: number, y: number, width: number, height: number): PromptOffset {
    return {
      dx: Math.max(0, Math.min(x, this.viewportWidth - width)),
      dy: Math.max(0, Math.min(y, this.viewportHeight - height)),
    };
  }
}
