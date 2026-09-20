import PolicyPage, { policyMetadata } from "../policy-page";

export const revalidate = 300;

export const generateMetadata = () => policyMetadata("privacy");

export default function Privacy() {
  return <PolicyPage kind="privacy" />;
}
