/*
 * Copyright (c) 2024 EKA2L1 Team.
 *
 * This file is part of EKA2L1 project.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */
#include <ios/launcher.h>

#include <system/epoc.h>
#include <system/devices.h>
#include <system/installation/firmware.h>
#include <system/installation/rpkg.h>

#include <kernel/kernel.h>

#include <config/app_settings.h>

#include <services/fbs/fbs.h>
#include <services/applist/applist.h>

#include <common/algorithm.h>
#include <common/buffer.h>
#include <common/cvt.h>
#include <common/fileutils.h>
#include <common/language.h>
#include <common/log.h>
#include <common/path.h>
#include <common/pystr.h>

#include <vfs/vfs.h>

#include <loader/mif.h>
#include <loader/mbm.h>
#include <loader/svgb.h>
#include <loader/nvg.h>

#include <utils/apacmd.h>
#include <utils/locale.h>
#include <utils/system.h>

#include <lunasvg.h>

#include <algorithm>

namespace eka2l1::ios {
    launcher::launcher(eka2l1::system *sys)
        : sys(sys)
        , conf(sys->get_config())
        , kern(sys->get_kernel_system())
        , alserv(nullptr)
        , winserv(nullptr)
        , fbsserv(nullptr)
        , rightsserv(nullptr)
        , scale_ratio_(100.0f)
        , scale_type_(1)
        , gravity_(2)
        , input_complete_callback_(nullptr)
        , yes_no_complete_callback_(nullptr) {
        background_color_[0] = 0;
        background_color_[1] = 0;
        background_color_[2] = 0;
        retrieve_servers();
    }

    void launcher::retrieve_servers() {
        if (kern) {
            alserv = reinterpret_cast<eka2l1::applist_server *>(kern->get_by_name<service::server>(get_app_list_server_name_by_epocver(
                kern->get_epoc_version())));
            winserv = reinterpret_cast<eka2l1::window_server *>(kern->get_by_name<service::server>(get_winserv_name_by_epocver(
                kern->get_epoc_version())));
            fbsserv = reinterpret_cast<eka2l1::fbs_server *>(kern->get_by_name<service::server>(epoc::get_fbs_server_name_by_epocver(
                kern->get_epoc_version())));
            rightsserv = reinterpret_cast<eka2l1::rights_server *>(kern->get_by_name<service::server>(eka2l1::RIGHTS_SERVER_NAME));
        }
    }

    static constexpr std::uint32_t WARE_APP_UID_START = 0x10300000;
    static inline bool is_reg_entry_probably_system_app(const apa_app_registry &reg) {
        return ((reg.land_drive == drive_z) && (reg.mandatory_info.uid < WARE_APP_UID_START));
    }

    std::vector<std::string> launcher::get_apps() {
        std::vector<std::string> info;
        if (!alserv) {
            return info;
        }

        std::vector<apa_app_registry> &registerations = alserv->get_registerations();
        for (auto &reg : registerations) {
            if (!reg.caps.is_hidden) {
                if (!conf || (conf && (!conf->hide_system_apps || (conf->hide_system_apps && !is_reg_entry_probably_system_app(reg))))) {
                    std::string name = common::ucs2_to_utf8(reg.mandatory_info.long_caption.to_std_string(nullptr));
                    std::string uid = std::to_string(reg.mandatory_info.uid);
                    info.push_back(uid);
                    info.push_back(name);
                }
            }
        }
        return info;
    }

    app_icon launcher::get_app_icon(std::uint32_t uid) {
        app_icon result;
        if (!alserv) {
            return result;
        }

        apa_app_registry *reg = alserv->get_registration(uid);
        if (!reg) {
            return result;
        }

        std::string app_name = common::ucs2_to_utf8(reg->mandatory_info.long_caption.to_std_string(nullptr));
        io_system *io = sys->get_io_system();

        const std::u16string path_ext = eka2l1::common::lowercase_ucs2_string(eka2l1::path_extension(reg->icon_file_path));

        if (path_ext == u".mif") {
            eka2l1::symfile file_route = io->open_file(reg->icon_file_path, READ_MODE | BIN_MODE);
            eka2l1::common::create_directories("cache");

            if (file_route) {
                const std::uint64_t mif_last_modified = file_route->last_modify_since_0ad();
                const std::string cached_path = fmt::format("cache/debinarized_{}.svg",
                    common::pystr(app_name).strip_reserverd().strip().std_str());

                std::unique_ptr<lunasvg::Document> document;

                if (eka2l1::common::exists(cached_path)) {
                    if (eka2l1::common::get_last_modifiy_since_ad(eka2l1::common::utf8_to_ucs2(cached_path)) >= mif_last_modified) {
                        document = lunasvg::Document::loadFromFile(cached_path.c_str());
                    }
                }

                eka2l1::ro_file_stream file_route_stream(file_route.get());
                eka2l1::loader::mif_file file_mif_parser(reinterpret_cast<eka2l1::common::ro_stream *>(&file_route_stream));

                if (!document && file_mif_parser.do_parse()) {
                    std::vector<std::uint8_t> data;
                    int dest_size = 0;
                    if (file_mif_parser.read_mif_entry(0, nullptr, dest_size)) {
                        if (dest_size != 0) {
                            data.resize(dest_size);
                            file_mif_parser.read_mif_entry(0, data.data(), dest_size);

                            eka2l1::common::ro_buf_stream inside_stream(data.data(), data.size());
                            std::unique_ptr<eka2l1::common::wo_std_file_stream> outfile_stream =
                                std::make_unique<eka2l1::common::wo_std_file_stream>(cached_path, true);

                            eka2l1::loader::mif_icon_header header;
                            inside_stream.read(&header, sizeof(eka2l1::loader::mif_icon_header));

                            std::vector<eka2l1::loader::svgb_convert_error_description> errors;
                            std::vector<eka2l1::loader::nvg_convert_error_description> errors_nvg;

                            if (header.type == eka2l1::loader::mif_icon_type_svg) {
                                if (!eka2l1::loader::convert_svgb_to_svg(inside_stream, *outfile_stream, errors)) {
                                    if (!errors.empty() && errors[0].reason_ == eka2l1::loader::svgb_convert_error_invalid_file) {
                                        outfile_stream->write(reinterpret_cast<const char *>(data.data()) + sizeof(eka2l1::loader::mif_icon_header), data.size() - sizeof(eka2l1::loader::mif_icon_header));
                                    }
                                }

                                outfile_stream.reset();
                                document = lunasvg::Document::loadFromFile(cached_path.c_str());
                            } else {
                                inside_stream = eka2l1::common::ro_buf_stream(data.data() + sizeof(eka2l1::loader::mif_icon_header),
                                    data.size() - sizeof(eka2l1::loader::mif_icon_header));

                                if (eka2l1::loader::convert_nvg_to_svg(inside_stream, *outfile_stream, errors_nvg)) {
                                    outfile_stream.reset();
                                    document = lunasvg::Document::loadFromFile(cached_path.c_str());
                                } else {
                                    outfile_stream.reset();
                                    eka2l1::common::remove(cached_path);
                                }
                            }
                        }
                    }
                }

                if (document) {
                    std::uint32_t width = document->width();
                    std::uint32_t height = document->height();
                    if ((width > 0) && (height > 0)) {
                        result.rgba.resize(static_cast<std::size_t>(width) * height * 4);
                        auto bitmap = lunasvg::Bitmap(result.rgba.data(), width, height, width * 4);
                        lunasvg::Matrix matrix{ 1, 0, 0, 1, 0, 0 };
                        document->render(bitmap, matrix);
                        bitmap.convertToRGBA();
                        result.width = static_cast<int>(width);
                        result.height = static_cast<int>(height);
                    }
                }
            }
        } else if (path_ext == u".mbm") {
            eka2l1::symfile file_route = io->open_file(reg->icon_file_path, READ_MODE | BIN_MODE);
            if (file_route) {
                eka2l1::ro_file_stream file_route_stream(file_route.get());
                eka2l1::loader::mbm_file file_mbm_parser(reinterpret_cast<eka2l1::common::ro_stream *>(&file_route_stream));

                if (file_mbm_parser.do_read_headers() && !file_mbm_parser.sbm_headers.empty()) {
                    eka2l1::loader::sbm_header *icon_header = &file_mbm_parser.sbm_headers[0];

                    const int w = icon_header->size_pixels.x;
                    const int h = icon_header->size_pixels.y;
                    result.rgba.resize(static_cast<std::size_t>(w) * h * 4);

                    eka2l1::common::wo_buf_stream converted_write_stream(result.rgba.data(), result.rgba.size());
                    if (eka2l1::epoc::convert_to_rgba8888(fbsserv, file_mbm_parser, 0, converted_write_stream)) {
                        result.width = w;
                        result.height = h;
                    } else {
                        result.rgba.clear();
                    }
                }
            }
        } else {
            std::optional<eka2l1::apa_app_masked_icon_bitmap> icon_pair = alserv->get_icon(*reg, 0);

            if (icon_pair.has_value()) {
                eka2l1::epoc::bitwise_bitmap *main_bitmap = icon_pair->first;
                const int w = main_bitmap->header_.size_pixels.x;
                const int h = main_bitmap->header_.size_pixels.y;
                result.rgba.resize(static_cast<std::size_t>(w) * h * 4);

                eka2l1::common::wo_buf_stream main_bitmap_buf(result.rgba.data(), result.rgba.size());
                if (eka2l1::epoc::convert_to_rgba8888(fbsserv, main_bitmap, main_bitmap_buf)) {
                    result.width = w;
                    result.height = h;
                } else {
                    result.rgba.clear();
                }
            }
        }

        return result;
    }

    void launcher::launch_app(std::uint32_t uid) {
        if (!alserv) {
            return;
        }

        apa_app_registry *reg = alserv->get_registration(uid);
        if (!reg) {
            return;
        }

        epoc::apa::command_line cmdline;
        cmdline.launch_cmd_ = epoc::apa::command_create;

        kern->lock();
        alserv->launch_app(*reg, cmdline, nullptr, [this](kernel::process *pr) {
            if (app_exit_callback_) {
                app_exit_callback_();
            }
        });
        kern->unlock();
    }

    package::installation_result launcher::install_app(std::string &path) {
        std::u16string upath = common::utf8_to_ucs2(path);
        drive_number install_drive = drive_number::drive_e;

        if (sys->is_s80_device_active()) {
            install_drive = drive_number::drive_d;
        }

        package::installation_result result =
            static_cast<package::installation_result>(sys->install_package(upath, install_drive));

        // Refresh the app-list server so the newly installed app appears immediately
        // (otherwise it is only picked up on the next boot's registry rescan).
        if ((result == package::installation_result_success) && alserv) {
            kern->lock();
            alserv->rescan_registries(sys->get_io_system());
            kern->unlock();
        }

        return result;
    }

    std::vector<std::string> launcher::get_devices() {
        device_manager *dvc_mngr = sys->get_device_manager();
        auto &dvcs = dvc_mngr->get_devices();
        std::vector<std::string> info;
        for (auto &device : dvcs) {
            info.push_back(device.model);
        }
        return info;
    }

    std::vector<std::string> launcher::get_device_firmware_codes() {
        device_manager *dvc_mngr = sys->get_device_manager();
        auto &dvcs = dvc_mngr->get_devices();
        std::vector<std::string> info;
        for (auto &device : dvcs) {
            info.push_back(device.firmware_code);
        }
        return info;
    }

    void launcher::set_language_to_property(const language new_one) {
        property_ptr lang_prop = kern->get_prop(epoc::SYS_CATEGORY, epoc::LOCALE_LANG_KEY);
        if (!lang_prop) {
            return;
        }
        auto current_lang = lang_prop->get_pkg<epoc::locale_language>();
        if (!current_lang) {
            return;
        }

        current_lang->language = static_cast<epoc::language>(new_one);
        lang_prop->set<epoc::locale_language>(current_lang.value());
    }

    void launcher::set_language_current(const language lang) {
        conf->language = static_cast<int>(lang);
        sys->set_system_language(lang);
        set_language_to_property(lang);
    }

    void launcher::set_current_device(std::uint32_t id, const bool temporary) {
        device_manager *dvc_mngr = sys->get_device_manager();
        auto &dvcs = dvc_mngr->get_devices();

        if (id >= dvcs.size()) {
            return;
        }

        if (conf->device != static_cast<int>(id)) {
            // Each device has its own language: adopt the target's chosen one (or its ROM
            // default if it has none yet) rather than carrying over the previous device's.
            const int target_lang = (dvcs[id].language >= 0) ? dvcs[id].language : dvcs[id].default_language_code;
            set_language_current(static_cast<language>(target_lang));

            if (temporary) {
                sys->set_device(id);
                retrieve_servers();
            } else {
                conf->device = id;
                conf->serialize();

                if (dvc_mngr) {
                    dvc_mngr->set_current(id);
                }
            }
        }
    }

    void launcher::rename_device(std::uint32_t id, const std::string &new_name) {
        device_manager *dvc_mngr = sys->get_device_manager();
        auto &dvcs = dvc_mngr->get_devices();
        if (id >= dvcs.size()) {
            return;
        }
        dvcs[id].model = new_name;
        dvc_mngr->save_devices();
    }

    std::vector<int> launcher::get_device_languages(std::uint32_t id) {
        device_manager *dvc_mngr = sys->get_device_manager();
        auto &dvcs = dvc_mngr->get_devices();
        if (id >= dvcs.size()) {
            return {};
        }
        return dvcs[id].languages;
    }

    int launcher::get_device_language(std::uint32_t id) {
        device_manager *dvc_mngr = sys->get_device_manager();
        auto &dvcs = dvc_mngr->get_devices();
        if (id >= dvcs.size()) {
            return -1;
        }
        // The device's own chosen language, or its ROM default if it hasn't been set yet.
        return (dvcs[id].language >= 0) ? dvcs[id].language : dvcs[id].default_language_code;
    }

    void launcher::set_device_language(std::uint32_t id, int language_id) {
        device_manager *dvc_mngr = sys->get_device_manager();
        auto &dvcs = dvc_mngr->get_devices();
        if (id >= dvcs.size()) {
            return;
        }

        // Remember the language on the device itself (persisted in devices.yml) so each device
        // keeps its own language independently.
        dvcs[id].language = language_id;
        dvc_mngr->save_devices();

        // If this is the currently-booted device, mirror it into the live config too — the
        // bridge reboots in place right after, and stage_one re-derives conf->language from the
        // booting device (so a non-current device just stores the choice, no reboot needed).
        if (static_cast<int>(id) == conf->device) {
            conf->language = language_id;
            conf->serialize();
        }
    }

    int launcher::delete_device(std::uint32_t index) {
        device_manager *dvc_mngr = sys->get_device_manager();
        auto &dvcs = dvc_mngr->get_devices();
        if (index >= dvcs.size()) {
            return dvc_mngr->get_current_index();
        }

        const std::string firmcode = dvcs[index].firmware_code;
        dvc_mngr->delete_device(firmcode);

        // delete_device already shifts/clamps the manager's current index; mirror it into
        // the config so the next boot selects a valid device.
        const int new_current = dvc_mngr->get_current_index();
        conf->device = (new_current < 0) ? 0 : new_current;
        conf->serialize();
        return new_current;
    }

    void launcher::rescan_devices() {
        sys->rescan_devices(drive_z);
    }

    int launcher::install_ngage_game(const std::string &folder_path, std::string &out_name) {
        ngage_game_card_install_error err = sys->install_ngage_game_card(folder_path,
            [&out_name](const std::string &name) { out_name = name; }, nullptr);

        // Mirror the desktop frontend: refresh the app-list registry so the freshly
        // installed game appears without a full reboot.
        if ((err == ngage_game_card_install_success) && alserv) {
            kern->lock();
            alserv->rescan_registries(sys->get_io_system());
            kern->unlock();
        }
        return static_cast<int>(err);
    }

    int launcher::install_ngage_file(const std::string &src_path, std::string &out_name) {
        // On Android an ".n-gage" game file is installed by dropping it into
        // <data>/drives/e/n-gage/. Replicate that: copy the file into the E drive's
        // "n-gage" folder, creating it if needed. The guest's N-Gage launcher reads it
        // from there directly, so no host-side mounting/registration is required.
        io_system *io = sys->get_io_system();
        auto drive_entry = io->get_drive_entry(drive_e);
        if (!drive_entry) {
            return -1;
        }

        std::string current_dir;
        common::get_current_directory(current_dir);
        const std::string e_root = eka2l1::absolute_path(drive_entry->real_path, current_dir);
        const std::string ngage_dir = eka2l1::add_path(e_root, "n-gage");
        eka2l1::common::create_directories(ngage_dir);

        const std::string base = eka2l1::filename(src_path);
        if (base.empty()) {
            return -2;
        }

        const std::string dest_name = common::is_platform_case_sensitive() ? common::lowercase_string(base) : base;
        if (dest_name != base) {
            common::remove(eka2l1::add_path(ngage_dir, base));
        }

        const std::string dest = eka2l1::add_path(ngage_dir, dest_name);
        if (!eka2l1::common::copy_file(src_path, dest, true)) {
            return -2;
        }

        out_name = base;
        LOG_INFO(FRONTEND_CMDLINE, "Copied N-Gage package '{}' to '{}'", src_path, dest);
        return 0;
    }

    std::uint32_t launcher::get_current_device() {
        return conf->device;
    }

    bool launcher::does_rom_need_rpkg(const std::string &rom_path) {
        return loader::should_install_requires_additional_rpkg(rom_path);
    }

    device_installation_error launcher::install_device(std::string &rpkg_path, std::string &rom_path, bool install_rpkg,
        progress_changed_callback progress_cb) {
        std::string firmware_code;
        device_manager *dvc_mngr = sys->get_device_manager();
        device_installation_error result;

        std::string root_c_path = add_path(conf->storage, "drives/c/");
        std::string root_e_path = add_path(conf->storage, "drives/e/");
        std::string root_z_path = add_path(conf->storage, "drives/z/");
        std::string rom_resident_path = add_path(conf->storage, "roms/");

        eka2l1::common::create_directories(rom_resident_path);

        bool need_add_rpkg = false;

        if (install_rpkg) {
            if (eka2l1::loader::should_install_requires_additional_rpkg(rom_path)) {
                result = eka2l1::loader::install_rpkg(dvc_mngr, rpkg_path, root_z_path, firmware_code, progress_cb, nullptr);
                need_add_rpkg = true;
            } else {
                result = eka2l1::loader::install_rom(dvc_mngr, rom_path, rom_resident_path, root_z_path, progress_cb, nullptr);
            }
        } else {
            result = eka2l1::install_firmware(
                dvc_mngr, rom_path, root_c_path, root_e_path, root_z_path, rom_resident_path,
                [](const std::vector<std::string> &variants) -> int { return 0; }, progress_cb, nullptr);
        }

        if (result != device_installation_none) {
            return result;
        }

        dvc_mngr->save_devices();

        if (need_add_rpkg) {
            const std::string rom_directory = add_path(conf->storage, add_path("roms", firmware_code + "\\"));
            eka2l1::common::create_directories(rom_directory);
            common::copy_file(rom_path, add_path(rom_directory, "SYM.ROM"), true);
        }

        return device_installation_none;
    }

    std::vector<std::string> launcher::get_packages() {
        manager::packages *manager = sys->get_packages();
        std::vector<std::string> info;
        if (!manager) {
            return info;
        }
        for (const auto &[pkg_uid, pkg] : *manager) {
            if (!pkg.is_removable) {
                continue;
            }
            info.push_back(std::to_string(pkg.uid));
            info.push_back(std::to_string(pkg.index));
            info.push_back(common::ucs2_to_utf8(pkg.package_name));
        }
        return info;
    }

    void launcher::uninstall_package(std::uint32_t uid, std::int32_t ext_index) {
        manager::packages *manager = sys->get_packages();
        if (!manager) {
            return;
        }
        package::object *obj = manager->package(uid, ext_index);
        if (obj) {
            manager->uninstall_package(*obj);
        }

        // The SIS uninstall above only deletes the files the package's controller registered
        // (its .exe, its own private dir, and the icons/metadata it stages into the N-Gage
        // "import" folder C:\private\20007B38\import). It deliberately does NOT touch the
        // runtime per-game record the N-Gage platform GENERATES from those import files under
        // the N-Gage store's private dir (uid 0x20007B39). On real hardware you uninstall an
        // N-Gage game through the N-Gage app, which clears that record; our package-list
        // uninstall bypasses it, so it survives and the guest's N-Gage installer aborts a
        // reinstall of the same game with KErrAlreadyExists (-11) — exactly the leftover a
        // full "Delete All App Data" wipes. Clean it up here so reinstalling works.
        remove_ngage_store_leftovers(uid);
    }

    void launcher::remove_ngage_store_leftovers(std::uint32_t uid) {
        io_system *io = sys->get_io_system();
        if (!io) {
            return;
        }

        // The N-Gage 2.0 platform keeps several per-game records that the SIS uninstall does NOT
        // cover (they're generated/staged by the platform, not listed in the package's controller).
        // On real hardware you uninstall a game through the N-Gage app, which clears all of these;
        // our package-list uninstall bypasses it, so they survive and the guest's N-Gage installer
        // aborts a reinstall of the same game with KErrAlreadyExists (-11). Remove them here so
        // reinstalling works (mirrors what a full "Delete All App Data" achieves). All paths are
        // keyed by the game's uid, so for an ordinary (non-N-Gage) SIS app these are harmless no-ops.
        const std::u16string uid_hex = common::utf8_to_ucs2(fmt::format("{:08x}", uid));
        const std::u16string game_dec = common::utf8_to_ucs2("game" + std::to_string(uid));
        const std::string image_prefix = fmt::format("{:08x}_", uid); // e.g. "2000afc0_"

        // The game (and its store record) can live on the system drive (C) or the removable drive
        // (E); get_raw_path returns nullopt for an unmounted drive, so probing both is safe.
        const char16_t drive_letters[] = { u'c', u'e' };
        for (char16_t letter : drive_letters) {
            const std::u16string drv = std::u16string(1, letter) + u":";

            // Store (uid 0x20007B39): per-game folders "game<decimal>" + "<hex8>" (promo art,
            // achievements, settings).
            const std::u16string store = drv + u"\\private\\20007b39\\";
            for (const std::u16string &child : { game_dec, uid_hex }) {
                if (std::optional<std::u16string> real_path = io->get_raw_path(store + child)) {
                    common::delete_folder(common::ucs2_to_utf8(real_path.value()));
                }
            }

            // Store cached artwork: images\game\<hex>_*.mbm — a folder shared by all games, so
            // remove only this uid's files by name rather than deleting the folder.
            if (std::optional<std::u16string> images_real = io->get_raw_path(store + u"images\\game\\")) {
                const std::string images_host = common::ucs2_to_utf8(images_real.value());
                if (auto it = common::make_directory_iterator(images_host, "")) {
                    it->detail = true;
                    common::dir_entry entry;
                    while (it->next_entry(entry) == 0) {
                        if ((entry.type != common::FILE_DIRECTORY) &&
                            (common::lowercase_string(entry.name).rfind(image_prefix, 0) == 0)) {
                            common::remove(eka2l1::add_path(images_host, entry.name));
                        }
                    }
                }
            }

            // Import handler (uid 0x20007B38): the platform's saved copy of the installer,
            // repository\<hex>.n-gage.
            const std::u16string repo = drv + u"\\private\\20007b38\\repository\\" + uid_hex + u".n-gage";
            if (std::optional<std::u16string> repo_real = io->get_raw_path(repo)) {
                common::remove(common::ucs2_to_utf8(repo_real.value()));
            }
        }
    }

    void launcher::mount_sd_card(std::string &path) {
        std::u16string upath = common::utf8_to_ucs2(path);
        io_system *io = sys->get_io_system();
        io->unmount(drive_e);
        io->mount_physical_path(drive_e, drive_media::physical,
            io_attrib_removeable | io_attrib_write_protected, upath);
    }

    void launcher::load_config() {
        conf->deserialize();
    }

    void launcher::set_screen_params(std::uint32_t background_color, std::uint32_t scale_ratio,
        std::uint32_t scale_type, std::uint32_t gravity) {
        background_color_[0] = (background_color >> 16) & 0xFF;
        background_color_[1] = (background_color >> 8) & 0xFF;
        background_color_[2] = background_color & 0xFF;
        scale_ratio_ = static_cast<float>(scale_ratio);
        scale_type_ = scale_type;
        gravity_ = gravity;
    }

    void launcher::set_screen_gravity(std::uint32_t gravity) {
        gravity_ = gravity;
    }

    void launcher::set_app_refresh_rate(std::uint32_t uid, std::uint32_t fps) {
        if (!kern) {
            return;
        }
        config::app_settings *settings = kern->get_app_settings();
        if (!settings) {
            return;
        }
        if (fps == 0) {
            fps = 1;
        }
        // Preserve any other per-app fields the core already tracks for this uid.
        config::app_setting updated;
        if (config::app_setting *existing = settings->get_setting(uid)) {
            updated = *existing;
        }
        updated.fps = fps;
        // add_or_replace_setting updates the in-memory map AND writes compat/<UID>.yml,
        // which the guest reads via screen::restore_from_config when the app's window group
        // is created (so the new rate takes effect on the next launch of this app).
        settings->add_or_replace_setting(uid, updated);
    }

    void launcher::set_app_filter_shader(std::uint32_t uid, const std::string &shader_name) {
        if (!kern) {
            return;
        }
        config::app_settings *settings = kern->get_app_settings();
        if (!settings) {
            return;
        }
        // Preserve the other per-app fields (fps etc.) the core already tracks for this uid.
        config::app_setting updated;
        if (config::app_setting *existing = settings->get_setting(uid)) {
            updated = *existing;
        }
        updated.filter_shader_path = shader_name;                          // "" = off (Default)
        updated.screen_upscale_method = shader_name.empty() ? 0u : 1u;     // lock the scale when a shader is on
        // Consumed by screen::restore_from_config (driver->set_upscale_shader) on the app's next launch.
        settings->add_or_replace_setting(uid, updated);
    }

    void launcher::draw(drivers::graphics_command_builder &builder, epoc::screen *scr,
        std::uint32_t window_width, std::uint32_t window_height) {
        eka2l1::rect viewport;
        eka2l1::rect src;
        eka2l1::rect dest;

        drivers::filter_option filter = conf->nearest_neighbor_filtering ? drivers::filter_option::nearest : drivers::filter_option::linear;

        eka2l1::vec2 swapchain_size(window_width, window_height);
        viewport.size = swapchain_size;

        builder.set_swapchain_size(swapchain_size);

        builder.backup_state();
        builder.bind_bitmap(0);

        builder.set_feature(drivers::graphics_feature::cull, false);
        builder.set_feature(drivers::graphics_feature::depth_test, false);
        builder.set_feature(eka2l1::drivers::graphics_feature::blend, false);
        builder.set_feature(drivers::graphics_feature::clipping, false);
        builder.set_feature(drivers::graphics_feature::stencil_test, false);
        builder.set_viewport(viewport);

        builder.clear({ background_color_[0] / 255.0f, background_color_[1] / 255.0f, background_color_[2] / 255.0f, 1.0f, 0.0f, 0.0f },
            drivers::draw_buffer_bit_color_buffer);

        if (scr) {
            auto &crr_mode = scr->current_mode();

            eka2l1::vec2 size = crr_mode.size;
            src.size = size;

            float width = 0;
            float height = 0;
            std::uint32_t x = 0;
            std::uint32_t y = 0;

            switch (scale_type_) {
                case 0:
                    width = size.x;
                    height = size.y;
                    break;
                case 1:
                    width = swapchain_size.x;
                    height = size.y * swapchain_size.x / size.x;

                    if (height > swapchain_size.y) {
                        height = swapchain_size.y;
                        width = size.x * swapchain_size.y / size.y;
                    }
                    break;
                case 2:
                    width = swapchain_size.x;
                    height = swapchain_size.y;
                    break;
            }

            width = width * scale_ratio_ / 100;
            height = height * scale_ratio_ / 100;

            switch (gravity_) {
                case 0:
                    x = 0;
                    y = (swapchain_size.y - height) / 2;
                    break;
                case 1:
                    x = (swapchain_size.x - width) / 2;
                    y = 0;
                    break;
                case 2:
                    x = (swapchain_size.x - width) / 2;
                    y = (swapchain_size.y - height) / 2;
                    break;
                case 3:
                    x = swapchain_size.x - width;
                    y = (swapchain_size.y - height) / 2;
                    break;
                case 4:
                    x = (swapchain_size.x - width) / 2;
                    y = swapchain_size.y - height;
                    break;
            }

            // Record the emulated screen's on-screen rectangle (post-rotation footprint, anchored
            // per the current gravity) as fractions of the surface, so the frontend can fit the
            // touch controls into the empty space beside/below the guest ("auto scale buttons").
            const float on_w = (scr->ui_rotation % 180 == 0) ? width : height;
            const float on_h = (scr->ui_rotation % 180 == 0) ? height : width;
            const float sw = static_cast<float>(swapchain_size.x);
            const float sh = static_cast<float>(swapchain_size.y);
            float ox = 0.0f, oy = 0.0f;
            switch (gravity_) {
                case 0: ox = 0;              oy = (sh - on_h) / 2; break;   // left
                case 1: ox = (sw - on_w)/2;  oy = 0;               break;   // top
                case 3: ox = sw - on_w;      oy = (sh - on_h) / 2; break;   // right
                case 4: ox = (sw - on_w)/2;  oy = sh - on_h;       break;   // bottom
                default: ox = (sw - on_w)/2; oy = (sh - on_h) / 2; break;   // centre
            }
            guest_fx_.store(sw > 0 ? ox / sw : 0.0f, std::memory_order_relaxed);
            guest_fy_.store(sh > 0 ? oy / sh : 0.0f, std::memory_order_relaxed);
            guest_fw_.store(sw > 0 ? on_w / sw : 1.0f, std::memory_order_relaxed);
            guest_fh_.store(sh > 0 ? on_h / sh : 1.0f, std::memory_order_relaxed);

            const float scale_x = width / static_cast<float>(size.x);
            const float scale_y = height / static_cast<float>(size.y);

            scr->set_native_scale_factor(sys->get_graphics_driver(), scale_x, scale_y);

            scr->absolute_pos.x = static_cast<int>(x);
            scr->absolute_pos.y = static_cast<int>(y);

            dest.top = eka2l1::vec2(x, y);
            dest.size = eka2l1::vec2(width, height);

            drivers::advance_draw_pos_around_origin(dest, scr->ui_rotation);

            if (scr->ui_rotation % 180 != 0) {
                std::swap(dest.size.x, dest.size.y);
                std::swap(src.size.x, src.size.y);
            }

            src.size *= scr->display_scale_factor;

            std::uint32_t flags = 0;
            if (scr->flags_ & epoc::screen::FLAG_SCREEN_UPSCALE_FACTOR_LOCK) {
                flags |= drivers::bitmap_draw_flag_use_upscale_shader;
            }

            builder.set_texture_filter(scr->screen_texture, true, filter);
            builder.set_texture_filter(scr->screen_texture, false, filter);
            builder.draw_bitmap(scr->screen_texture, 0, dest, src, eka2l1::vec2(0, 0),
                static_cast<float>(scr->ui_rotation), flags);
        }

        builder.load_backup_state();
    }

    bool launcher::open_input_view(const std::u16string &initial_text, const int max_len,
        drivers::ui::input_dialog_complete_callback complete_callback) {
        if (input_complete_callback_) {
            return false;
        }
        input_complete_callback_ = complete_callback;
        // No native text entry yet on iOS; immediately complete with the initial text so
        // the guest is not left waiting on a dialog that can never be dismissed.
        on_finished_text_input(common::ucs2_to_utf8(initial_text), true);
        return true;
    }

    void launcher::close_input_view() {
        input_complete_callback_ = nullptr;
    }

    void launcher::on_finished_text_input(const std::string &text, const bool force_close) {
        if (input_complete_callback_) {
            input_complete_callback_(common::utf8_to_ucs2(text));
            input_complete_callback_ = nullptr;
        }
    }

    bool launcher::open_question_dialog(const std::u16string &text, const std::u16string &button1_text,
        const std::u16string &button2_text, drivers::ui::yes_no_dialog_complete_callback complete_callback) {
        if (yes_no_complete_callback_) {
            return false;
        }
        yes_no_complete_callback_ = complete_callback;
        // Default to "yes" so guest flows that gate on a confirmation can proceed.
        on_question_dialog_finished(1);
        return true;
    }

    void launcher::on_question_dialog_finished(const int result) {
        if (yes_no_complete_callback_) {
            yes_no_complete_callback_(result);
            yes_no_complete_callback_ = nullptr;
        }
    }
}
