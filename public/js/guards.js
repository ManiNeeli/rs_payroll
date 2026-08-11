async function guardRole(requiredRole) {
  const {
    data: { session },
  } = await supabaseClient.auth.getSession();

  if (!session) {
    window.location.href = "/index.html";
    return;
  }

  const { data: profile, error } = await supabaseClient
    .from("profiles")
    .select("role, full_name")
    .eq("id", session.user.id)
    .single();

  if (error || !profile || profile.role !== requiredRole) {
    window.location.href = "/index.html";
    return;
  }

  renderTopbar(profile.role, profile.full_name);

  const nameEl = document.getElementById("welcomeName");
  if (nameEl) nameEl.textContent = profile.full_name;
}

function renderTopbar(role, fullName) {
  const navLinks = {
    admin: [
      ["dashboard.html", "Dashboard"],
      ["manage-employees.html", "Create Account"],
      ["payroll-approval.html", "Payroll Approval"],
    ],
    hr: [
      ["dashboard.html", "Dashboard"],
      ["employee-directory.html", "Directory"],
      ["attendance-management.html", "Attendance"],
      ["leave-approvals.html", "Leaves"],
      ["salary-structure.html", "Salary"],
      ["run-payroll.html", "Run Payroll"],
      ["payslip-guide.html", "Guide"],
    ],
    employee: [
      ["dashboard.html", "Dashboard"],
      ["my-attendance.html", "Attendance"],
      ["apply-leave.html", "Leave"],
      ["my-payslips.html", "Payslips"],
    ],
  };

  const links = (navLinks[role] || [])
    .map(([href, label]) => `<a href="${href}">${label}</a>`)
    .join("");

  const topbarHTML = `
    <div id="rsTopbar">
      <div class="brand">
        <img src="../assets/img/rs-logo.png" alt="RS Solutions logo" />
        <div class="brand-text">RS Solutions<small>Payroll & HR</small></div>
        <nav>${links}</nav>
      </div>
      <div class="right">
        <span class="role-badge">${role}</span>
        <span class="user-name">${fullName}</span>
        <button class="logout-btn" id="rsLogoutBtn">Log out</button>
      </div>
    </div>
  `;

  document.body.insertAdjacentHTML("afterbegin", topbarHTML);

  // Wrap the rest of the page content for consistent padding
  const wrapper = document.createElement("div");
  wrapper.className = "page-content";
  const topbar = document.getElementById("rsTopbar");
  let node = topbar.nextSibling;
  while (node) {
    const next = node.nextSibling;
    wrapper.appendChild(node);
    node = next;
  }
  document.body.appendChild(wrapper);

  document.getElementById("rsLogoutBtn").addEventListener("click", async () => {
    await supabaseClient.auth.signOut();
    window.location.href = "/index.html";
  });
}
