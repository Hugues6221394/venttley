import SignOutButton from "@/components/sign-out-button";

export default function Topbar({
  pseudonym,
  role,
}: {
  pseudonym: string;
  role: string;
}) {
  return (
    <header className="h-16 shrink-0 flex items-center justify-between px-6 bg-white/80 backdrop-blur border-b border-mauve/30">
      <div className="flex items-center gap-2 text-xs text-burgundy/60">
        <span className="h-2 w-2 rounded-full bg-ok" />
        <span>Connected to Supabase</span>
      </div>
      <div className="flex items-center gap-4">
        <div className="text-right leading-tight">
          <p className="text-sm font-extrabold text-burgundy">@{pseudonym}</p>
          <p className="text-[11px] uppercase tracking-widest text-burgundy/55">
            {role}
          </p>
        </div>
        <div className="h-9 w-9 rounded-full bg-berry/20 flex items-center justify-center text-burgundy font-bold">
          {pseudonym.charAt(0).toUpperCase()}
        </div>
        <SignOutButton />
      </div>
    </header>
  );
}
