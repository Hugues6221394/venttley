export function BrandMark({ size = 28 }: { size?: number }) {
  return (
    <span className="venttly-mark" aria-hidden="true" style={{ width: size, height: size }}>
      <img src="/brand/venttly-mark.png" alt="" width={size} height={size} />
    </span>
  );
}
