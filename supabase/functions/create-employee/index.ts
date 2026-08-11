import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json({ error: "Missing authorization" }, 401);

    const supabaseAuthClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } }
    );

    const { data: { user }, error: userError } = await supabaseAuthClient.auth.getUser();
    if (userError || !user) return json({ error: "Invalid session" }, 401);

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SERVICE_ROLE_KEY")!
    );

    const { data: callerProfile, error: profileErr } = await supabaseAdmin
      .from("profiles")
      .select("role")
      .eq("id", user.id)
      .single();

    if (profileErr || !callerProfile || callerProfile.role !== "admin") {
      return json({ error: "Only admins can create accounts" }, 403);
    }

    const body = await req.json();
    const {
      email, password, full_name, role, employee_id, department_id,
      designation, date_of_joining,
      // optional starting salary structure -- if the caller sends these,
      // we create the employee's first salary_structures row in the same
      // request instead of leaving them with none (which is what was
      // making run-payroll.html skip freshly created employees).
      salary,
    } = body;

    if (!email || !password || !full_name || !role) {
      return json({ error: "Missing required fields: email, password, full_name, role" }, 400);
    }
    if (!["admin", "hr", "employee"].includes(role)) {
      return json({ error: "role must be admin, hr, or employee" }, 400);
    }
    if (!employee_id || !employee_id.trim()) {
      return json({ error: "employee_id is required" }, 400);
    }

    // Fail fast on a duplicate employee_id BEFORE creating the auth user,
    // so we never end up with an auth account that has no usable profile.
    const { data: dupe } = await supabaseAdmin
      .from("profiles")
      .select("id")
      .eq("employee_id", employee_id.trim())
      .maybeSingle();
    if (dupe) {
      return json({ error: `Employee ID "${employee_id}" is already in use` }, 400);
    }

    const { data: newUser, error: createErr } = await supabaseAdmin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { full_name },
    });

    if (createErr || !newUser.user) {
      return json({ error: createErr?.message || "User creation failed" }, 400);
    }

    const userId = newUser.user.id;

    // Rollback helper: if anything after this point fails, delete the
    // auth user we just created rather than leaving an orphaned login
    // with no working profile / salary structure.
    const rollback = async () => {
      await supabaseAdmin.auth.admin.deleteUser(userId).catch(() => {});
    };

    const { error: upsertErr } = await supabaseAdmin
      .from("profiles")
      .upsert(
        {
          id: userId,
          full_name,
          role,
          employee_id: employee_id.trim(),
          department_id: department_id || null,
          designation: designation || null,
          date_of_joining: date_of_joining || null,
          status: "active",
        },
        { onConflict: "id" }
      );

    if (upsertErr) {
      await rollback();
      return json({ error: `Profile could not be saved: ${upsertErr.message}` }, 400);
    }

    if (salary && typeof salary === "object") {
      const {
        effective_from, basic, hra, da = 0, conveyance = 0,
        medical_allowance = 0, special_allowance = 0, other_allowances = 0,
        ctc_annual, pf_applicable = true, esi_applicable = false, tax_regime = "new",
      } = salary;

      if (effective_from && basic != null && ctc_annual != null) {
        const { error: salaryErr } = await supabaseAdmin.from("salary_structures").insert({
          employee_id: userId,
          effective_from,
          basic, hra, da, conveyance,
          medical_allowance, special_allowance, other_allowances,
          ctc_annual, pf_applicable, esi_applicable, tax_regime,
        });

        if (salaryErr) {
          await rollback();
          return json({ error: `Salary structure could not be saved: ${salaryErr.message}` }, 400);
        }
      }
    }

    return json({ success: true, user_id: userId });
  } catch (e) {
    return json({ error: e.message }, 500);
  }
});
