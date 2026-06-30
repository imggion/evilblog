(() => {
    const openButtons = document.querySelectorAll("[data-open-delete-dialog]");
    if (openButtons.length === 0 || typeof HTMLDialogElement !== "function") return;

    for (const button of openButtons) {
        const dialogId = button.getAttribute("data-open-delete-dialog");
        if (!dialogId) continue;

        const dialog = document.getElementById(dialogId);
        if (!(dialog instanceof HTMLDialogElement)) continue;

        button.addEventListener("click", () => {
            dialog.showModal();
        });

        const closeButton = dialog.querySelector("[data-close-delete-dialog]");
        if (closeButton) {
            closeButton.addEventListener("click", () => {
                dialog.close();
            });
        }
    }
})();
