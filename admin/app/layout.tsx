import "./globals.css";
import "./themes.css";
import type { Metadata } from "next";
import Script from "next/script";
import {themeBootstrap} from "@/lib/theme-preference";
import {ThemePreferenceProvider} from "@/components/theme-preference";

export const metadata: Metadata = {
  title: "Venttly Admin",
  description: "Anonymous emotional-support platform — operator console",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const themes=process.env.ADMIN_THEME_UI==="true";
  return (
    <html lang="en" data-theme-ui={themes?"enabled":undefined} data-theme={themes?"system":undefined} suppressHydrationWarning={themes}>
      {themes&&<Script id="console-theme-init" strategy="beforeInteractive">{themeBootstrap}</Script>}
      <body>{themes?<ThemePreferenceProvider>{children}</ThemePreferenceProvider>:children}</body>
    </html>
  );
}
