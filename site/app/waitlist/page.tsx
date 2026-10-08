import Link from "next/link";

import WaitlistForm from "./waitlist-form";

export const metadata = {
  title: "Venttly — join the waitlist",
  description:
    "Leave an email address and we will tell you once, when Venttly opens.",
  alternates: { canonical: "/waitlist" },
};

/**
 * The page that collects an address, and says what happens to it.
 *
 * The promises below are kept by the schema rather than by intention: the
 * table holds an address and a timestamp and has no column for anything else,
 * and the only route off the machine is a daily digest to the team. Saying so
 * here is the point — a product whose front page is about not giving your name
 * away has to be legible about the one piece of contact detail it does ask for.
 */
export default function Waitlist() {
  return (
    <main>
      <div className="wrap">
        <h1>Be told when Venttly opens.</h1>
        <p className="lede">
          Venttly is not open yet. Leave an email address and we will send you
          one message — the day it is.
        </p>

        <WaitlistForm />

        <h2>What we do with it</h2>
        <ul>
          <li>
            We store the address and the date you gave it. Nothing else — no
            name, no IP address, no tracking.
          </li>
          <li>
            We use it once, to tell you Venttly has launched. It is not a
            newsletter and we do not sell or share the list.
          </li>
          <li>
            Reply to that email, or write to{" "}
            <a href="mailto:info@codafriqa.rw">info@codafriqa.rw</a>, and we
            delete it.
          </li>
          <li>
            Joining the waitlist does not create a Venttly account, and asks
            nothing of you beyond the address itself.
          </li>
        </ul>

        <p>
          The <Link href="/privacy">Privacy Policy</Link> and{" "}
          <Link href="/terms">Terms &amp; Conditions</Link> apply to the app
          once you join it.
        </p>

        <p className="notice">
          Venttly is not a crisis service and not a substitute for professional
          care. If you are in immediate danger, contact your local emergency
          number.
        </p>
      </div>
    </main>
  );
}
