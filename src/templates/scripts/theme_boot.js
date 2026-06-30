(function () {
    function cleanTheme(theme) {
        return theme === "light" || theme === "dark" || theme === "system" ? theme : "system";
    }

    try {
        // This runs in <head> so the first paint uses the stored theme when
        // storage is available.
        document.documentElement.setAttribute(
            "data-theme",
            cleanTheme(localStorage.getItem("evilblog-theme") || "system")
        );
    } catch (_) {
        // Restricted storage should not block the page; the system theme is safe.
        document.documentElement.setAttribute("data-theme", "system");
    }
})();
