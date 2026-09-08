import { redirect } from "next/navigation";
import { currentUserId } from "@/lib/session";
import { requestMagicLink } from "./actions";

export const metadata = { title: "Sign in · Weed Man Mailing Program" };

export default async function SignIn({
  searchParams,
}: {
  searchParams: Promise<{ e?: string }>;
}) {
  if (await currentUserId()) redirect("/");
  const { e } = await searchParams;

  return (
    <>
      <header className="topbar">
        <div>
          <div className="wm">DIS DIRECT</div>
          <div className="sub">Mailing Program</div>
        </div>
      </header>

      <main className="narrow">
        <p className="kicker">Weed Man</p>
        <h1>Sign in</h1>
        <p className="lede">
          Enter the email address DIS Direct set your account up with. We will send you a
          link that signs you in — there is no password to remember.
        </p>

        <form action={requestMagicLink} className="stack" style={{ marginTop: 26 }}>
          {e === "format" ? (
            <p className="warn">
              That does not look like an email address. Check for a typo and try again.
            </p>
          ) : null}

          <div className="card stack">
            <label>
              Email address
              <input
                type="email"
                name="email"
                required
                autoComplete="email"
                autoFocus
                placeholder="you@yourfranchise.com"
                spellCheck={false}
              />
            </label>
            <button className="btn" type="submit">
              Email me a sign-in link
            </button>
            <p className="notice">
              The link works once and expires shortly. Signing in does not by itself give
              you access to a franchise — DIS Direct grants that separately.
            </p>
          </div>
        </form>

        <p className="notice" style={{ marginTop: 22 }}>
          Trouble getting in? Contact your DIS Direct rep rather than requesting link
          after link — repeated requests are rate limited.
        </p>
      </main>
    </>
  );
}
