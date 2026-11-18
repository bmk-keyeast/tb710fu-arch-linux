/* Included by kShimC's tests/ui_preview_test.c: the TB710FU main menu at the panel's resolution,
 * with the rows platform.c builds for tb710fu_android_defconfig (.github/workflows/kshim-themes.yml). */
static void RenderTb710fu(const char *Directory)
{
    const uint32_t Width = 3200U, Height = 2000U;
    size_t Bytes = (size_t)Width * Height * sizeof(uint32_t);
    uint32_t *Pixels = calloc(1U, Bytes);
    assert(Pixels != NULL);

    kshim_framebuffer_config_t Config = {
        .render_address = (uintptr_t)Pixels,
        .width = Width,
        .height = Height,
        .stride = Width * sizeof(uint32_t),
        .bpp = 32U,
        .format = KSHIM_FB_FORMAT_XRGB8888,
        .buffer_size = Bytes,
    };
    kshim_framebuffer_t Framebuffer;
    assert(kshim_fb_init(&Framebuffer, &Config) == KSHIM_FB_OK);

    QcomKeyDescriptor Descriptors[3];
    const uint32_t Codes[] = {
        QCOM_KEYCODE_VOLUMEUP, QCOM_KEYCODE_VOLUMEDOWN, QCOM_KEYCODE_POWER,
    };
    for (size_t Index = 0; Index < 3U; Index++)
        assert(QcomKeyMakeGpioAt(&Descriptors[Index], Index + 1U, 1U, Codes[Index], 0U) == 0);
    QcomKeys Keys;
    memset(Inputs, 0, sizeof(Inputs));
    assert(QcomKeysInit(&Keys, Descriptors, 3U, ReadInput, NULL) == 0);

    kshim_lvgl_set_scratch(Scratch, sizeof(Scratch));
    kshim_lvgl_t Ui;
    assert(kshim_lvgl_init(&Ui, &Framebuffer, &Keys) == 0);

    static const kshim_menu_role_t Roles[7] = {
        KSHIM_MENU_ROLE_ANDROID, KSHIM_MENU_ROLE_UNKNOWN, KSHIM_MENU_ROLE_ADVANCED,
        KSHIM_MENU_ROLE_LANGUAGE, KSHIM_MENU_ROLE_DEVICE_INFO,
        KSHIM_MENU_ROLE_RESTART, KSHIM_MENU_ROLE_OFF,
    };
    const char *Names[7], *Descriptions[7], *Actions[7];
    for (size_t Index = 0; Index < 7U; Index++) {
        Names[Index] = kshim_menu_role_name(Roles[Index], "Arch Linux");
        Descriptions[Index] = kshim_menu_role_description(Roles[Index], "");
    }
    Names[0] = "Android";
    Actions[0] = KSHIM_MENU_ACTION_BOOT;
    Actions[1] = KSHIM_MENU_ACTION_BOOT;
    Actions[2] = KSHIM_MENU_ACTION_ENTER;
    Actions[3] = KSHIM_MENU_ACTION_ENTER;
    Actions[4] = KSHIM_MENU_ACTION_ENTER;
    Actions[5] = KSHIM_MENU_ACTION_RESTART;
    Actions[6] = KSHIM_MENU_ACTION_OFF;

    assert(kshim_lvgl_set_entries_described(&Ui, (const char *const *)Names,
        (const char *const *)Descriptions, (const char *const *)Actions, 7U, 0U) == 0);
    kshim_lvgl_set_entry_roles(&Ui, Roles, 7U);
    kshim_lvgl_set_countdown(&Ui, Ui.ElapsedMs + 8000U);
    Advance(&Ui, 600U);
    (void)WritePpm(Directory, "tb710fu", &Framebuffer);

    kshim_lvgl_deinit(&Ui);
    free(Pixels);
}
