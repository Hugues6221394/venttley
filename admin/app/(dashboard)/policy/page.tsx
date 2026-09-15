import { redirect } from "next/navigation";

export default function PolicyIndexPage() {
  redirect("/policy/versions");
}
