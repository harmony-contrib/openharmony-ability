const NativeMock: Record<string, object> = {
  add: (a: number, b: number) => {
    return a + b;
  },
};

export default NativeMock;
