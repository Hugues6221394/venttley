export default function ComingSoon({
  title,
  description,
}: {
  title: string;
  description: string;
}) {
  return (
    <div className="flex flex-col gap-6 max-w-3xl">
      <div>
        <h1 className="text-2xl font-extrabold text-burgundy">{title}</h1>
        <p className="text-sm text-burgundy/65 mt-1">{description}</p>
      </div>
      <div className="card p-10 text-center">
        <p className="text-4xl mb-2">🌿</p>
        <p className="text-base font-extrabold text-burgundy">
          Coming in the next release
        </p>
        <p className="text-sm text-burgundy/65 mt-2">
          This panel ships once the v1 launch settles. The MVP focuses on the
          three operator-critical surfaces: Overview, Moderation, Users.
        </p>
      </div>
    </div>
  );
}
