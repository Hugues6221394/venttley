import "./globals.css";
import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Venttly Admin",
  description: "Anonymous emotional-support platform — operator console",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
