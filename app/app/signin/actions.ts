"use server";

import { redirect } from "next/navigation";
import { signIn } from "@/auth";
import { logAuthEvent, magicLinkAllowed, requestContext } from "@/lib/authlog";

/** Cheap shape check. Deliverability is the email provider's problem. */
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

/**
 * Request a magic link.
 *
 * Every path through this function ends at the same place with the same
 * message. That is the point, and it is worth stating plainly because it looks
 * like sloppy error handling:
 *
 *   - address not registered  -> "check your email"
 *   - address registered      -> "check your email"
 *   - rate limited            -> "check your email"
 *   - email provider errored  -> "check your email"
 *
 * Anything else leaks. Different copy, a different status, or even a
 * noticeably different response time tells an attacker which of your 100
 * franchisees' addresses are real, which is exactly the list they want before
 * going after a mailbox. The real outcome is recorded in auth_events, where
 * staff can see it and the browser cannot.
 *
 * The one exception is a malformed address, which is a typo rather than a
 * probe, and telling someone they mistyped their own email leaks nothing.
 */
export async function requestMagicLink(formData: FormData): Promise<void> {
  const raw = String(formData.get("email") ?? "");
  const email = raw.trim().toLowerCase();
  const { ip, ua } = await requestContext();

  if (!EMAIL.test(email)) {
    redirect("/signin?e=format");
  }

  const gate = await magicLinkAllowed(email, ip);

  if (!gate.allowed) {
    await logAuthEvent("link_rate_limited", {
      email,
      ip,
      userAgent: ua,
      detail: { emailCount: gate.emailCount, ipCount: gate.ipCount },
    });
    redirect("/signin/sent");
  }

  await logAuthEvent("link_requested", { email, ip, userAgent: ua });

  try {
    // redirect:false so a provider failure cannot bounce the user somewhere
    // that would reveal whether the address exists.
    await signIn("nodemailer", { email, redirect: false });
  } catch (err) {
    await logAuthEvent("link_send_failed", {
      email,
      ip,
      userAgent: ua,
      detail: { error: err instanceof Error ? err.message : String(err) },
    });
  }

  redirect("/signin/sent");
}
