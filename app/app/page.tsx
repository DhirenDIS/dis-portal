import { signOut } from "@/auth";
import { currentUserId, myFranchises, isStaff } from "@/lib/session";
import { redirect } from "next/navigation";

export default async function Home() {
  const userId = await currentUserId();
  if (!userId) redirect("/signin");

  // Both come from the database under RLS, never from the session cookie.
  const [franchises, staff] = await Promise.all([
    myFranchises(userId),
    isStaff(userId),
  ]);

  return (
    <>
      <header className="topbar">
        <div>
          <div className="wm">DIS DIRECT</div>
          <div className="sub">Mailing Program</div>
        </div>
        <div className="spacer" />
        <form
          action={async () => {
            "use server";
            await signOut({ redirectTo: "/signin" });
          }}
        >
          <button type="submit">Sign out</button>
        </form>
      </header>

      <main>
        <p className="kicker">{staff ? "DIS Direct staff" : "Weed Man"}</p>
        <h1>{franchises.length === 1 ? franchises[0]!.name : "Your franchises"}</h1>

        {franchises.length === 0 ? (
          <>
            <p className="lede">
              You are signed in, but no franchise has been assigned to this account yet.
            </p>
            <div className="empty" style={{ marginTop: 20 }}>
              Nothing to show. Your DIS Direct rep grants portal access per franchise —
              ask them to add you, then reload this page.
            </div>
          </>
        ) : (
          <>
            <p className="lede">
              {franchises.length === 1
                ? "Start a mailing or a door hanger drop for this location."
                : "Pick the location you want to order for."}
            </p>
            <div className="grid" style={{ marginTop: 22 }}>
              {franchises.map((f) => (
                <div className="card stack" key={f.id}>
                  <div>
                    <h2 style={{ fontSize: 18 }}>{f.name}</h2>
                    <p className="notice">
                      {f.city}, {f.state}
                    </p>
                  </div>
                  <dl className="kv">
                    <dt>Phone</dt>
                    <dd>{f.phone ?? "—"}</dd>
                    <dt>Web</dt>
                    <dd>{f.web ?? "—"}</dd>
                    <dt>Home ZIP</dt>
                    <dd>{f.home_zip ?? "—"}</dd>
                    <dt>Billing</dt>
                    <dd>
                      {f.billing_method === "invoice_corporate"
                        ? "Invoiced to corporate"
                        : "Invoiced to the franchise"}
                    </dd>
                  </dl>
                  <p className="notice">Ordering is not wired up yet.</p>
                </div>
              ))}
            </div>
          </>
        )}
      </main>
    </>
  );
}
