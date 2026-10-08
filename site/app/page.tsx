import Link from "next/link";

export const metadata = {
  title: "Venttly — say it without your name attached",
  alternates: { canonical: "/" },
};

/**
 * A holding page, deliberately small.
 *
 * It exists because both app stores require a reachable privacy policy URL,
 * and because a domain whose only live host was a staff login gate is exactly
 * the shape a phishing classifier flags — which is what happened to
 * admin.venttly.com. This gives the domain something honest to be.
 */
export default function Home() {
  return (
    <main>
      <div className="wrap hero">
        <h1>Say it without your name attached.</h1>
        <p className="lede">
          Venttly is a pseudonymous space for emotional support. You vent, you
          listen, you find people who understand — under a handle, not a name.
        </p>

        {/* The app is not out yet, so the one thing a visitor can actually do
            is ask to be told when it is. It sits above the explanation rather
            than under it: somebody who already knows what Venttly is should
            not have to read three cards to find the only button. */}
        <p>
          <Link className="cta" href="/waitlist">
            Join the waitlist
          </Link>
        </p>

        <div className="cards">
          <div className="card">
            <h2>Pseudonymous by default</h2>
            <p>
              No real name, no phone number in your profile, no contact upload.
              Your handle is how people know you.
            </p>
          </div>
          <div className="card">
            <h2>Moderated by people</h2>
            <p>
              Reports reach a trained team. Decisions are explained, and every
              one of them can be appealed to someone who did not make it.
            </p>
          </div>
          <div className="card">
            <h2>Yours to leave</h2>
            <p>
              Delete your account from inside the app. Your posts and messages
              go with it.
            </p>
          </div>
        </div>

        <p>
          Venttly is not a crisis service and not a substitute for professional
          care. If you are in immediate danger, contact your local emergency
          number.
        </p>

        <p>
          Read the <Link href="/privacy">Privacy Policy</Link> and{" "}
          <Link href="/terms">Terms &amp; Conditions</Link>.
        </p>
      </div>
    </main>
  );
}
