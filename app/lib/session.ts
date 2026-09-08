/**
 * Who is signed in, and what they may act for.
 *
 * requireOperator() is the gate every operator page goes through: it resolves
 * the session, then asks the DATABASE which franchises that user may act for.
 * The franchise list is never taken from the session or a cookie - it comes
 * from franchise_operators under RLS, so it cannot be tampered with client-side.
 */
import { redirect } from "next/navigation";
import { auth } from "@/auth";
import { asUser } from "@/lib/db";

export type Franchise = {
  id: string;
  name: string;
  city: string;
  state: string;
  phone: string | null;
  web: string | null;
  home_zip: string | null;
  billing_method: string;
};

export async function currentUserId(): Promise<string | null> {
  const session = await auth();
  return session?.user?.id ?? null;
}

export async function requireUserId(): Promise<string> {
  const id = await currentUserId();
  if (!id) redirect("/signin");
  return id;
}

/** The franchises this user may act for, straight from the database. */
export async function myFranchises(userId: string): Promise<Franchise[]> {
  return asUser(userId, async (c) => {
    const r = await c.query(
      `select id, name, city, state, phone, web, home_zip, billing_method
         from franchises
        order by name`,
    );
    return r.rows as Franchise[];
  });
}

export async function isStaff(userId: string): Promise<boolean> {
  return asUser(userId, async (c) => {
    const r = await c.query("select public.is_staff() as staff");
    return Boolean(r.rows[0]?.staff);
  });
}
