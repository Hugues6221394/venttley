import LoginForm from "@/components/login-form";

export default function LoginPage() {
  return (
    <main className="min-h-screen flex items-center justify-center bg-gradient-to-br from-blush to-cardBlush px-6">
      <div className="card w-full max-w-sm p-8">
        <div className="flex flex-col items-center mb-6">
          <div className="h-14 w-14 rounded-2xl bg-berry flex items-center justify-center text-white text-2xl shadow-card">
            ♡
          </div>
          <h1 className="mt-4 text-xl font-extrabold text-burgundy">
            Venttly Admin
          </h1>
          <p className="text-xs text-burgundy/60 mt-1">
            Super-admin access only.
          </p>
        </div>
        <LoginForm />
      </div>
    </main>
  );
}
