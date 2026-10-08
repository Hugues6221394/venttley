import type { Metadata } from "next";
import Link from "next/link";
import "./globals.css";

export const metadata: Metadata = {
  metadataBase: new URL("https://venttly.com"),
  title: {
    default: "Venttly",
    template: "%s · Venttly",
  },
  description:
    "Venttly is a pseudonymous space for emotional support. Vent, listen, and find people who understand — without your name attached.",
  openGraph: {
    type: "website",
    siteName: "Venttly",
    url: "https://venttly.com",
  },
  // The App Store and Play Store listings both link here, and a store reviewer
  // following that link is the first visitor this site will ever have.
  robots: { index: true, follow: true },
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body>
        <header>
          <div className="wrap bar">
            <div className="mark" aria-hidden="true">
              ♥
            </div>
            <strong>Venttly</strong>
            <nav>
              <Link href="/waitlist">Waitlist</Link>
              <Link href="/privacy">Privacy</Link>
              <Link href="/terms">Terms</Link>
            </nav>
          </div>
        </header>

        {children}

        <footer>
          <div className="wrap">
            <div className="links">
              <Link href="/privacy">Privacy Policy</Link>
              <Link href="/terms">Terms &amp; Conditions</Link>
              <a href="mailto:support@venttly.com">support@venttly.com</a>
            </div>
            <div>Venttly is a product of CODAFRIQA.</div>
          </div>
        </footer>
      </body>
    </html>
  );
}
