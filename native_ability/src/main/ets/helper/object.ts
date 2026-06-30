export function objectAssign(
  target: Record<string, Object>,
  ...source: Object[]
): Record<string, Object> {
  for (const items of source) {
    for (const key of Object.keys(items)) {
      target[key] = (items as Record<string, Object>)[key];
    }
  }
  return target;
}
