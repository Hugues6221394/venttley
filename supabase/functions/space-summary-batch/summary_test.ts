import { buildSummary } from "./summary.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

Deno.test("space summaries use aggregate moods and deterministic copy", () => {
  const result = buildSummary(7, [
    { post_mood: "anxious", vent_count: 4 },
    { post_mood: "hopeful", vent_count: 3 },
  ]);
  assert(
    result.summary.includes("7 people"),
    "aggregate count should be described",
  );
  assert(
    result.topMoods.join(",") === "anxious,hopeful",
    "top moods should be retained",
  );
  assert(
    !result.summary.includes("vent body"),
    "no content should be required",
  );
});
