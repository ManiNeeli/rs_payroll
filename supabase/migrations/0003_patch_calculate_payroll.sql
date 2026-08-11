-- =====================================================================
-- PATCH: calculate_payroll() robustness fixes
--
-- Your statutory_settings / tax_slabs / company_holidays columns are
-- correct, so this does NOT change your payroll math for the data you
-- have today. It only guards against two latent issues:
--
--   1. Division by zero if a month somehow has 0 working days.
--   2. tax_slabs.financial_year was never filtered on, so slabs from
--      every financial year you've ever entered get mixed into the
--      TDS calculation for every regime. Only affects you the moment
--      you add a second year of slabs, but silently gives wrong TDS
--      when it does -- no error, just a wrong number on a payslip.
--
-- financial_year is stored like '2025-26' -- derived from p_month/p_year
-- using the standard Apr-Mar Indian financial year.
-- =====================================================================

create or replace function public.calculate_payroll(p_employee_id uuid, p_month integer, p_year integer)
 returns table(out_employee_id uuid, days_in_month integer, working_days integer, days_present numeric, lop_days numeric, gross_earnings numeric, basic numeric, hra numeric, da numeric, allowances numeric, bonus_total numeric, pf_employee numeric, pf_employer numeric, esi_employee numeric, esi_employer numeric, professional_tax numeric, tds numeric, other_deductions numeric, net_pay numeric)
 language plpgsql
 security definer
as $function$
declare
  v_salary record;
  v_statutory record;
  v_days_in_month int;
  v_working_days int;
  v_present_days numeric;
  v_leave_days numeric;
  v_lop_days numeric;
  v_ratio numeric;
  v_monthly_gross numeric;
  v_payable_gross numeric;
  v_basic numeric;
  v_hra numeric;
  v_da numeric;
  v_allowances numeric;
  v_pf_wage numeric;
  v_pf_emp numeric;
  v_pf_er numeric;
  v_esi_emp numeric;
  v_esi_er numeric;
  v_pt numeric;
  v_annual_taxable numeric;
  v_tax numeric := 0;
  v_cess numeric;
  v_monthly_tds numeric;
  v_bonus numeric;
  v_other_ded numeric;
  v_financial_year text;
  slab record;
begin
  select * into v_salary
  from salary_structures s
  where s.employee_id = p_employee_id
    and s.effective_from <= make_date(p_year, p_month, 1)
  order by s.effective_from desc
  limit 1;

  if v_salary is null then
    raise exception 'No salary structure found for employee';
  end if;

  select * into v_statutory
  from statutory_settings
  where effective_from <= make_date(p_year, p_month, 1)
  order by effective_from desc
  limit 1;

  if v_statutory is null then
    raise exception 'No statutory settings found effective on or before %-%', p_month, p_year;
  end if;

  v_days_in_month := extract(day from (make_date(p_year, p_month, 1) + interval '1 month - 1 day'));

  -- Count working days: exclude Sat/Sun and company holidays
  select count(*) into v_working_days
  from generate_series(make_date(p_year, p_month, 1), (make_date(p_year, p_month, 1) + interval '1 month - 1 day')::date, '1 day') as d
  where extract(dow from d) not in (0,6)
    and d::date not in (select holiday_date from company_holidays);

  if coalesce(v_working_days, 0) = 0 then
    raise exception 'Working days calculated as 0 for %-% -- check company_holidays for that month', p_month, p_year;
  end if;

  select count(*) filter (where a.status = 'present') into v_present_days
  from attendance a
  where a.employee_id = p_employee_id
    and extract(month from a.date) = p_month
    and extract(year from a.date) = p_year;

  select count(*) filter (where a.status = 'leave') into v_leave_days
  from attendance a
  where a.employee_id = p_employee_id
    and extract(month from a.date) = p_month
    and extract(year from a.date) = p_year;

  v_lop_days := greatest(v_working_days - coalesce(v_present_days,0) - coalesce(v_leave_days,0), 0);

  v_monthly_gross := v_salary.basic + v_salary.hra + v_salary.da + v_salary.conveyance
                      + v_salary.medical_allowance + v_salary.special_allowance + v_salary.other_allowances;

  v_ratio := (v_working_days - v_lop_days) / v_working_days::numeric;
  v_payable_gross := v_monthly_gross * v_ratio;

  v_basic := v_salary.basic * v_ratio;
  v_hra := v_salary.hra * v_ratio;
  v_da := v_salary.da * v_ratio;
  v_allowances := (v_salary.conveyance + v_salary.medical_allowance + v_salary.special_allowance + v_salary.other_allowances) * v_ratio;

  select coalesce(sum(b.amount),0) into v_bonus from bonuses b
  where b.employee_id = p_employee_id;

  select coalesce(sum(d.amount),0) into v_other_ded from deductions d
  where d.employee_id = p_employee_id;

  if v_salary.pf_applicable then
    v_pf_wage := least(v_basic + v_da, v_statutory.pf_wage_ceiling);
    v_pf_emp := round(v_pf_wage * v_statutory.pf_employee_percent / 100, 2);
    v_pf_er := round(v_pf_wage * v_statutory.pf_employer_percent / 100, 2);
  else
    v_pf_emp := 0; v_pf_er := 0;
  end if;

  if v_salary.esi_applicable and v_payable_gross <= v_statutory.esi_wage_ceiling then
    v_esi_emp := round(v_payable_gross * v_statutory.esi_employee_percent / 100, 2);
    v_esi_er := round(v_payable_gross * v_statutory.esi_employer_percent / 100, 2);
  else
    v_esi_emp := 0; v_esi_er := 0;
  end if;

  v_pt := v_statutory.professional_tax;

  v_annual_taxable := greatest(v_monthly_gross * 12 - 75000, 0);

  -- Indian financial year: Apr(4)-Dec(12) of p_year belongs to FY p_year-(p_year+1);
  -- Jan(1)-Mar(3) of p_year belongs to FY (p_year-1)-p_year.
  if p_month >= 4 then
    v_financial_year := p_year || '-' || right((p_year + 1)::text, 2);
  else
    v_financial_year := (p_year - 1) || '-' || right(p_year::text, 2);
  end if;

  for slab in
    select * from tax_slabs t
    where t.regime = v_salary.tax_regime
      and t.financial_year = v_financial_year
    order by t.min_income asc
  loop
    if v_annual_taxable > slab.min_income then
      v_tax := v_tax + (least(v_annual_taxable, coalesce(slab.max_income, v_annual_taxable)) - slab.min_income) * slab.rate_percent / 100;
    end if;
  end loop;

  if v_salary.tax_regime = 'new' and v_annual_taxable <= 1200000 then
    v_tax := 0;
  end if;

  v_cess := v_tax * 0.04;
  v_monthly_tds := round((v_tax + v_cess) / 12, 2);

  return query select
    p_employee_id,
    v_days_in_month,
    v_working_days,
    coalesce(v_present_days,0) + coalesce(v_leave_days,0),
    v_lop_days,
    round(v_payable_gross + v_bonus, 2),
    round(v_basic,2), round(v_hra,2), round(v_da,2), round(v_allowances,2),
    v_bonus,
    v_pf_emp, v_pf_er,
    v_esi_emp, v_esi_er,
    v_pt,
    v_monthly_tds,
    v_other_ded,
    round(v_payable_gross + v_bonus - v_pf_emp - v_esi_emp - v_pt - v_monthly_tds - v_other_ded, 2);
end;
$function$
;
