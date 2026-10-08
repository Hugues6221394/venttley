"use client";

import { useState } from "react";

/**
 * The only form on the site.
 *
 * It calls public.waitlist_join over PostgREST with the same publishable key
 * the policy pages read with. That function is SECURITY DEFINER and returns
 * void: anon has EXECUTE on it and no rights at all on waitlist_signups, so
 * this page can add an address and cannot read, count, or test for one.
 *
 * Which is also why the success state says the same thing whether the address
 * was new or already there. The function cannot tell us, on purpose — "you
 * are already on this list" is a membership answer, and this is a list about
 * mental health.
 */

type State =
  | { status: "idle" }
  | { status: "sending" }
  | { status: "done" }
  | { status: "error"; message: string };

const GENERIC_ERROR =
  "We couldn't add you just now. Please try again in a moment.";

export default function WaitlistForm() {
  const [email, setEmail] = useState("");
  const [state, setState] = useState<State>({ status: "idle" });
  // Bots fill every field they find. People never see this one, so anything
  // in it means the submission was not typed. Cheaper and quieter than a
  // captcha, which is the wrong first impression for this particular product.
  const [botField, setBotField] = useState("");

  async function onSubmit(event: React.FormEvent) {
    event.preventDefault();
    if (state.status === "sending") return;

    const trimmed = email.trim();
    if (!trimmed) {
      setState({ status: "error", message: "Enter your email address." });
      return;
    }
    // Answered here as well as in the database, so a typo is caught while
    // somebody is still looking at the field.
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]{2,}$/.test(trimmed)) {
      setState({
        status: "error",
        message: "That email address doesn't look right.",
      });
      return;
    }
    if (botField) {
      // Told the same thing a person is told. A bot that learns which
      // submissions were dropped learns how to avoid the trap.
      setState({ status: "done" });
      return;
    }

    setState({ status: "sending" });

    const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
    const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
    if (!url || !key) {
      setState({ status: "error", message: GENERIC_ERROR });
      return;
    }

    try {
      const res = await fetch(`${url}/rest/v1/rpc/waitlist_join`, {
        method: "POST",
        headers: {
          apikey: key,
          Authorization: `Bearer ${key}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ p_email: trimmed }),
      });

      if (!res.ok) {
        // The one case worth naming. Everything else — a 500, a dropped
        // connection, PostgREST having a bad day — is not this person's
        // problem to interpret, and the raw body never reaches the screen.
        const body = await res.text();
        if (body.includes("waitlist_email_invalid")) {
          setState({
            status: "error",
            message: "That email address doesn't look right.",
          });
          return;
        }
        setState({ status: "error", message: GENERIC_ERROR });
        return;
      }

      setState({ status: "done" });
      setEmail("");
    } catch {
      setState({ status: "error", message: GENERIC_ERROR });
    }
  }

  if (state.status === "done") {
    return (
      <div className="notice" role="status">
        <strong>You&apos;re on the list.</strong> We&apos;ll email you once —
        when Venttly opens. Nothing else, and you can reply to that email to
        be taken off.
      </div>
    );
  }

  return (
    <form className="join" onSubmit={onSubmit} noValidate>
      <label className="sr-only" htmlFor="waitlist-email">
        Email address
      </label>
      <div className="join-row">
        <input
          id="waitlist-email"
          type="email"
          inputMode="email"
          autoComplete="email"
          placeholder="you@example.com"
          value={email}
          onChange={(e) => {
            setEmail(e.target.value);
            if (state.status === "error") setState({ status: "idle" });
          }}
          aria-invalid={state.status === "error"}
          aria-describedby={state.status === "error" ? "waitlist-error" : undefined}
        />
        <button type="submit" disabled={state.status === "sending"}>
          {state.status === "sending" ? "Adding…" : "Notify me"}
        </button>
      </div>

      {/* Off-screen rather than display:none — some bots skip hidden fields. */}
      <div className="trap" aria-hidden="true">
        <label htmlFor="waitlist-company">Company</label>
        <input
          id="waitlist-company"
          name="company"
          type="text"
          tabIndex={-1}
          autoComplete="off"
          value={botField}
          onChange={(e) => setBotField(e.target.value)}
        />
      </div>

      {state.status === "error" ? (
        <p className="join-error" id="waitlist-error" role="alert">
          {state.message}
        </p>
      ) : null}
    </form>
  );
}
