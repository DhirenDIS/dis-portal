/**
 * Auth.js configuration - magic-link sign-in only.
 *
 * Operators never set a password. They enter their email, get a one-time link,
 * and land signed in. Sessions are stored in Postgres (the `sessions` table
 * from db/migrations/0007), not in a JWT, so revoking access is a delete.
 *
 * Signing in grants NOTHING on its own. Access comes from a franchise_operators
 * row, which only DIS staff can create. A stranger who requests a link for
 * their own address gets a valid session and sees an empty portal.
 */

import NextAuth from "next-auth";
import PostgresAdapter from "@auth/pg-adapter";
import Nodemailer from "next-auth/providers/nodemailer";
import { pool } from "@/lib/db";
import { logAuthEvent } from "@/lib/authlog";

const FROM = process.env.EMAIL_FROM ?? "portal@disdirect.com";

/**
 * Deliver the magic link.
 *
 * Three paths, in order of preference. The last one only exists for local
 * development and refuses to run in production - quietly writing sign-in links
 * to a log file instead of emailing them would be both a broken product and a
 * standing credential leak.
 */
async function sendVerificationRequest(params: {
  identifier: string;
  url: string;
  provider: { from?: string };
}) {
  const { identifier: email, url } = params;
  const subject = "Your sign-in link for the Weed Man mailing portal";
  const text =
    "Sign in to the mailing portal:\n\n" +
    url +
    "\n\nThis link works once and expires shortly. " +
    "If you did not ask for it, you can ignore this email.\n";

  if (process.env.RESEND_API_KEY) {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: "Bearer " + process.env.RESEND_API_KEY,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ from: FROM, to: [email], subject, text }),
    });
    if (!res.ok) {
      throw new Error(
        "Resend refused the magic link (" + res.status + "): " + (await res.text()),
      );
    }
    return;
  }

  if (process.env.EMAIL_SERVER) {
    const { createTransport } = await import("nodemailer");
    await createTransport(process.env.EMAIL_SERVER).sendMail({
      to: email,
      from: FROM,
      subject,
      text,
    });
    return;
  }

  if (process.env.NODE_ENV === "production") {
    throw new Error(
      "No email sender configured. Set RESEND_API_KEY (or EMAIL_SERVER) on the " +
        "Railway service, or nobody can sign in.",
    );
  }

  // Development only.
  console.log("\n=== magic link (dev: no email sender configured) ===");
  console.log("  to:  " + email);
  console.log("  url: " + url);
  console.log("===================================================\n");
}

export const { handlers, signIn, signOut, auth } = NextAuth({
  adapter: PostgresAdapter(pool),
  session: {
    strategy: "database",
    // 8 hours absolute, sliding by an hour of activity. Short enough that a
    // forgotten session on a shared machine expires the same day; long enough
    // that a franchisee building an order does not get logged out mid-flow.
    // Database-backed, so revoking is a delete rather than waiting it out.
    maxAge: 8 * 60 * 60,
    updateAge: 60 * 60,
  },
  pages: { signIn: "/signin", verifyRequest: "/signin/sent", error: "/signin" },
  providers: [
    Nodemailer({
      from: FROM,
      // `server` is unused because sendVerificationRequest is overridden, but
      // the provider requires the field to be present.
      server: process.env.EMAIL_SERVER ?? "smtp://unused:unused@localhost:25",
      sendVerificationRequest,
    }),
  ],
  events: {
    async signIn({ user }) {
      await logAuthEvent("signin_succeeded", { email: user.email, userId: user.id });
    },
    async signOut(message) {
      const userId =
        "session" in message && message.session && "userId" in message.session
          ? (message.session.userId as string)
          : null;
      await logAuthEvent("signout", { userId });
    },
  },
  callbacks: {
    async session({ session, user }) {
      // Expose the app_users id; every RLS policy keys off it.
      if (session.user) session.user.id = user.id;
      return session;
    },
  },
  trustHost: true, // Railway terminates TLS upstream
});
