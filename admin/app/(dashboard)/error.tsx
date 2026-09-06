"use client";

import { ErrorPanel } from "@/components/ui/empty-state";

/**
 * Server Actions now reject malformed input by throwing (lib/validate.ts) and
 * refuse to run past a rate limit (lib/guard.ts). Without a boundary those
 * throws replace the whole console with Next's default error screen, which
 * for an operator mid-triage looks like the tool broke rather than like the
 * tool declined.
 *
 * Next redacts server error messages in production, so `error.message` is
 * only the specific reason in development; in production it is a generic
 * string with a digest. Surfacing per-field messages next to the inputs
 * needs the actions converted to useActionState, which is a larger change
 * than this one — noted in the README rather than half-done here.
 */
export default function DashboardError({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  return (
    <div className="max-w-[700px]">
      <ErrorPanel
        title="That action didn't go through."
        detail={error.message}
        hint={
          error.digest
            ? `Nothing was changed. Reference ${error.digest} if you need to report this.`
            : "Nothing was changed. Check the values you entered and try again."
        }
      />
      <button type="button" onClick={reset} className="btn-secondary mt-4">
        Try again
      </button>
    </div>
  );
}
