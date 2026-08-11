# RS Company — Employee Management & Payroll System

A full role-based Employee Management and Payroll web application built with plain HTML/CSS/JavaScript on the frontend and Supabase (Postgres, Auth, Row Level Security, Edge Functions) on the backend. Supports statutory India-style payroll: PF, ESI, Professional Tax, and slab-based TDS, alongside attendance and leave tracking.

## Roles

- **Admin** — creates HR/Employee accounts, approves payroll runs, views company-wide reports
- **HR** — manages employee records, attendance corrections, leave approvals, salary structures, and runs monthly payroll
- **Employee** — checks in/out, applies for leave, views their own profile, and downloads payslips as PDF

## Tech Stack

- **Frontend:** HTML, CSS, vanilla JavaScript (no build step, no framework)
- **Backend:** [Supabase](https://supabase.com) — Postgres database, Authentication, Row Level Security, and one Edge Function (for secure account creation)
- **PDF generation:** [jsPDF](https://github.com/parallax/jsPDF) + [jspdf-autotable](https://github.com/simonbengtsson/jsPDF-AutoTable)
- **Charts:** [Chart.js](https://www.chartjs.org/)

## Features

- Secure authentication with role-based access control, enforced both in the UI and at the database level via RLS
- Attendance check-in/check-out with HR correction tools
- Leave application, approval workflow, and automatic leave-balance + attendance sync
- Configurable salary structures (Basic, HRA, DA, allowances) per employee, versioned by effective date
- Statutory payroll engine: attendance-based pro-rating, PF (12%/12%, capped), ESI (0.75%/3.25%, conditional), flat Professional Tax, and slab-based TDS with Section 87A rebate handling
- Monthly payroll run + Admin approval workflow
- Employee payslip viewer with downloadable, PDF payslips
- Role-specific dashboards with live summary cards and a payroll cost trend chart

## Project Structure

```
pay_roll/
├── index.html                  # Login page
├── public/
│   ├── assets/                 # CSS and images
│   ├── js/                     # Shared client, auth, and role-guard scripts
│   ├── admin/                  # Admin-only pages
│   ├── hr/                     # HR-only pages
│   └── employee/               # Employee-only pages
└── supabase/
    └── functions/
        └── create-employee/    # Edge Function for secure account creation
```

## Setup

1. Create a project at [supabase.com](https://supabase.com) and note your **Project URL** and **anon/publishable key**.
2. Update `public/js/supabaseClient.js` with those two values.
3. Run the SQL migrations (tables, RLS policies, and the `calculate_payroll` function) in the Supabase SQL Editor.
4. Deploy the Edge Function:
   ```
   supabase link --project-ref YOUR_PROJECT_REF
   supabase secrets set SERVICE_ROLE_KEY=your_secret_key
   supabase functions deploy create-employee --no-verify-jwt
   ```
5. Create your first Admin account by signing up, then promoting that user's `role` to `admin` directly in the `profiles` table.
6. Serve the project locally with VS Code's **Live Server** extension (Supabase Auth requires an `http://` origin, not `file://`).

## Security Notes

- Row Level Security is enabled on every table; every policy has been tested by attempting to bypass it as a lower-privileged role.
- The Supabase `service_role`/secret key is never exposed to the frontend — it lives only in the Edge Function's server-side environment.
- Employees can only check themselves in for the current date with a locked `present` status, preventing attendance fabrication.

## License

Built as a learning/portfolio project.

1.Team lead=====24881A1278-SriManiHarika Battu 
2.Member========24881A12G7-ManiRaj Neeli