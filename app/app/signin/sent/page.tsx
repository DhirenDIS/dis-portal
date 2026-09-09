import { TopBar, WeedManMark } from "@/app/brand";

export const metadata = { title: "Check your email · Weed Man Mailing Program" };

/**
 * Deliberately says the same thing whatever happened: address unknown, link
 * sent, rate limited, or the provider failed. See app/signin/actions.ts.
 */
export default function LinkSent() {
  return (
    <>
      <TopBar />

      <main className="narrow">
        <div className="clientmark">
          <WeedManMark height={32} />
          <span className="rule" />
        </div>
        <h1>Check your email</h1>
        <p className="lede">
          If that address has an account, a sign-in link is on its way. It works once and
          expires shortly.
        </p>

        <div className="card stack" style={{ marginTop: 24 }}>
          <p className="notice">
            Not arrived after a minute or two? Check spam. If it is not there, the address
            may not be set up yet — your DIS Direct rep can confirm.
          </p>
          <p className="notice">
            You can close this tab. The link opens the portal directly.
          </p>
        </div>

        <p className="notice" style={{ marginTop: 22 }}>
          <a href="/signin">Use a different address</a>
        </p>
      </main>
    </>
  );
}
