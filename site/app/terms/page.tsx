import PolicyPage, { policyMetadata } from "../policy-page";

export const revalidate = 300;

export const generateMetadata = () => policyMetadata("terms");

export default function Terms() {
  return <PolicyPage kind="terms" />;
}
