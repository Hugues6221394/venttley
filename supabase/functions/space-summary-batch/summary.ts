export interface MoodRow {
  post_mood: string;
  vent_count: number;
}

export function buildSummary(
  total: number,
  moods: MoodRow[],
): { summary: string; topMoods: string[]; prompt: string } {
  const topMoods = moods.slice(0, 3).map((row) => row.post_mood);
  const readable = topMoods.map((mood) => mood.replaceAll("_", " "));
  const moodText = readable.length === 1
    ? readable[0]
    : readable.length === 2
    ? `${readable[0]} and ${readable[1]}`
    : `${readable[0]}, ${readable[1]}, and ${readable[2]}`;
  const summary = total === 1
    ? `One person shared how they are feeling today. The mood they chose was ${moodText}.`
    : `${total} people shared how they are feeling today. The most selected moods were ${moodText}.`;
  return {
    summary,
    topMoods,
    prompt: promptForMood(topMoods[0]),
  };
}

function promptForMood(mood: string | undefined): string {
  switch (mood) {
    case "anxious":
    case "overthinking":
      return "What is one small thing helping you feel grounded today?";
    case "sad":
    case "lonely":
    case "broken":
      return "What kind of support would feel helpful right now?";
    case "angry":
    case "exhausted":
      return "What do you wish people understood about your day?";
    case "happy":
    case "grateful":
    case "hopeful":
    case "healing":
      return "What is one moment you would like to carry into tomorrow?";
    default:
      return "What has been on your mind today?";
  }
}
