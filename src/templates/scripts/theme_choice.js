(function () {
    var select = document.getElementById("theme-choice");
    if (!select) return;

    function cleanTheme(theme) {
        return theme === "light" || theme === "dark" || theme === "system" ? theme : "system";
    }

    function storedTheme() {
        try {
            return cleanTheme(localStorage.getItem("evilblog-theme") || "system");
        } catch (_) {
            return "system";
        }
    }

    function writeTheme(theme) {
        document.documentElement.setAttribute("data-theme", theme);
        try {
            localStorage.setItem("evilblog-theme", theme);
        } catch (_) {
            // Applying the theme for this page is still useful when persistence
            // is unavailable.
        }
    }

    select.value = storedTheme();
    select.addEventListener("change", function () {
        writeTheme(cleanTheme(select.value));
    });
})();
