/**
 * Brand marks.
 *
 * Both are the real assets, not type substitutes: the Weed Man wordmark is
 * their official logo, and the DIS Direct lockup is rendered from
 * DIS_LogoNEW.pdf.
 *
 * The DIS lockup is blue-and-black on white, so it cannot be reversed onto the
 * navy bar - inverting it would turn the blue mark orange. It sits on a white
 * plate instead, which is the conventional treatment for a full-colour mark on
 * a dark ground.
 *
 * Plain <img> rather than next/image: two small static logos do not need the
 * optimizer, and this keeps the pages independent of sharp being present at
 * runtime. Width and height are set so nothing reflows as they load.
 */

export function DisDirectMark({ height = 34 }: { height?: number }) {
  // Asset is 480x149.
  const width = Math.round((height * 480) / 149);
  return (
    <span className="displate" style={{ height, padding: "6px 10px" }}>
      <img
        src="/brand/dis-direct.png"
        alt="DIS Direct"
        width={width}
        height={height}
        style={{ display: "block", height, width: "auto" }}
      />
    </span>
  );
}

export function WeedManMark({ height = 30 }: { height?: number }) {
  // Asset is 400x66.
  const width = Math.round((height * 400) / 66);
  return (
    <img
      src="/brand/weed-man.png"
      alt="Weed Man"
      width={width}
      height={height}
      style={{ display: "block", height, width: "auto" }}
    />
  );
}

/**
 * The bar across the top of every page: DIS Direct as the platform, with the
 * programme name beside it. `right` takes the sign-out button where there is
 * a session.
 */
export function TopBar({ right }: { right?: React.ReactNode }) {
  return (
    <header className="topbar">
      <DisDirectMark />
      <span className="barsep" aria-hidden="true" />
      <span className="sub">Mailing Program</span>
      <div className="spacer" />
      {right}
    </header>
  );
}
