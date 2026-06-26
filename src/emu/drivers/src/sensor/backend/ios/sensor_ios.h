/*
 * Copyright (c) 2026 EKA2L1 Team.
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

#pragma once

#include <common/linked.h>
#include <drivers/sensor/sensor.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <vector>

namespace eka2l1::drivers {
    class sensor_driver_ios;

    // Shared buffering/callback target for one accelerometer listener. Held by the sensor via a
    // shared_ptr and handed to the CoreMotion handler block as a weak_ptr: a background sample that
    // is already mid-delivery keeps the sink alive (via the upgraded shared_ptr) even if the owning
    // sensor channel is closed concurrently on the guest thread — so there is no use-after-free, and
    // the guest callback (which takes the kernel lock) never runs while any of our locks are held.
    struct accel_sink {
        std::mutex lock_;
        std::vector<std::uint8_t> buffer_;
        std::size_t desired_ = 1;
        std::size_t queried_ = 0;
        sensor_data_callback callback_;
        std::atomic<std::uint32_t> measure_range_index_{ 0 };

        // Arm a fresh data request: deliver once `desired` samples have been collected.
        void set_request(std::size_t desired, sensor_data_callback callback);
        // Feed one raw CoreMotion sample (acceleration in g on each axis). Fires the callback when
        // the requested number of samples has accumulated.
        void deliver(double gx, double gy, double gz);
    };

    class sensor_ios : public sensor {
    private:
        friend class sensor_driver_ios;

        sensor_driver_ios *driver_;
        sensor_info info_;
        bool is_accelerometer_;
        bool listening_;

        std::shared_ptr<accel_sink> sink_;

        std::uint32_t packet_size_;
        std::uint32_t active_accel_measure_range_;
        std::uint32_t active_sampling_rate_;

        common::double_linked_queue_element listening_link_;

        void start_updates();
        void stop_updates();

    public:
        explicit sensor_ios(sensor_driver_ios *driver, const sensor_info &info);
        ~sensor_ios() override;

        bool get_property(const sensor_property prop, const std::int32_t item_index,
            const std::int32_t array_index, sensor_property_data &data) override;
        bool set_property(const sensor_property_data &data) override;
        std::vector<sensor_property_data> get_all_properties(const sensor_property *prop_value = nullptr) override;

        bool listen_for_data(std::size_t desired_buffering_count, std::size_t max_buffering_count, std::size_t delay_us) override;
        bool cancel_data_listening() override;
        void pause_data_listening();
        void resume_data_listening();

        void receive_data(sensor_data_callback callback) override;

        std::uint32_t data_packet_size() const override {
            return packet_size_;
        }
    };

    class sensor_driver_ios : public sensor_driver {
    private:
        friend class sensor_ios;

        // CMMotionManager* and a serial NSOperationQueue*, retained (CFBridgingRetain) so the pure
        // C++ header stays Objective-C-free; resolved back with __bridge in the .mm.
        void *motion_manager_;
        void *delivery_queue_;

        common::roundabout listening_list_;
        bool paused_;

        std::vector<sensor_info> infos_;

    public:
        explicit sensor_driver_ios();
        ~sensor_driver_ios() override;

        std::vector<sensor_info> queries_active_sensor(const sensor_info &search_info) override;
        std::unique_ptr<sensor> new_sensor_controller(const std::uint32_t id) override;

        bool pause() override;
        bool resume() override;

        void track_active_listener(common::double_linked_queue_element *link);

        void *motion_manager() { return motion_manager_; }
        void *delivery_queue() { return delivery_queue_; }
    };
}
