async function login(email, password) {
  const { data, error } = await supabaseClient.auth.signInWithPassword({
    email,
    password,
  });

  if (error) {
    document.getElementById("errorMsg").textContent = error.message;
    return;
  }

  const { data: profile, error: profileError } = await supabaseClient
    .from("profiles")
    .select("role")
    .eq("id", data.user.id)
    .single();

  if (profileError) {
    document.getElementById("errorMsg").textContent =
      "Could not load user profile.";
    return;
  }

  if (profile.role === "admin") {
    window.location.href = "public/admin/dashboard.html";
  } else if (profile.role === "hr") {
    window.location.href = "public/hr/dashboard.html";
  } else {
    window.location.href = "public/employee/dashboard.html";
  }
}

document.getElementById("loginForm").addEventListener("submit", (e) => {
  e.preventDefault();
  const email = document.getElementById("email").value;
  const password = document.getElementById("password").value;
  login(email, password);
});
