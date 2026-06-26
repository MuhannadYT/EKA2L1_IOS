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

#include "sensor_ios.h"
#include "../null/sensor_null.h"

#include <common/log.h>
#include <common/time.h>

#import <CoreMotion/CoreMotion.h>
#import <Foundation/Foundation.h>

namespace eka2l1::drivers {
    // Mirror the Android backend's accelerometer constants so games see identical scaling/ranges
    // (these were themselves taken from the Nokia 5800 XpressMusic accelerometer).
    static constexpr std::int32_t ACCELEROMETER_SCALE_RANGE_MAX = 127;
    static constexpr std::int32_t ACCELEROMETER_SCALE_RANGE_MIN = -128;
    static const double ACCELEROMETER_MEASURE_RANGE_AVAILABLE[] = { 19.62, 78.48 };
    static const std::int32_t SAMPLING_RATE_AVAILABLE[] = { 10, 40, 50 };
    static const std::int32_t ACCELEROMETER_MEASURE_RANGE_MAX_OPTION =
        sizeof(ACCELEROMETER_MEASURE_RANGE_AVAILABLE) / sizeof(double);
    static const std::int32_t SAMPLING_RATE_MAX_OPTION =
        sizeof(SAMPLING_RATE_AVAILABLE) / sizeof(std::int32_t);

    // 1 g in m/s^2. CoreMotion reports acceleration in g; Android (and therefore the guest's scaling
    // above) works in m/s^2, so convert. The sign is flipped because iOS measures the reaction force
    // with the opposite convention to Android — negating each axis makes a given physical tilt produce
    // the same guest reading it would on Android.
    static constexpr double IOS_GRAVITY_MS2 = 9.80665;

    void accel_sink::set_request(std::size_t desired, sensor_data_callback callback) {
        const std::lock_guard<std::mutex> guard(lock_);
        if (callback_) {
            return;   // a data request is already pending
        }
        desired_ = desired ? desired : 1;
        queried_ = 0;
        buffer_.clear();
        callback_ = std::move(callback);
    }

    void accel_sink::deliver(double gx, double gy, double gz) {
        std::vector<std::uint8_t> out;
        std::size_t count = 0;
        sensor_data_callback fire;
        {
            const std::lock_guard<std::mutex> guard(lock_);
            if (!callback_) {
                return;   // nothing waiting for data right now → drop the sample
            }

            std::uint32_t range_index = measure_range_index_.load(std::memory_order_relaxed);
            if (range_index >= static_cast<std::uint32_t>(ACCELEROMETER_MEASURE_RANGE_MAX_OPTION)) {
                range_index = 0;
            }
            const double measure_range = ACCELEROMETER_MEASURE_RANGE_AVAILABLE[range_index];

            sensor_accelerometer_axis_data axis_data;
            axis_data.timestamp_ = common::get_current_utc_time_in_microseconds_since_0ad();
            axis_data.axis_x_ = static_cast<std::int32_t>(-gx * IOS_GRAVITY_MS2 * ACCELEROMETER_SCALE_RANGE_MAX / measure_range);
            axis_data.axis_y_ = static_cast<std::int32_t>(-gy * IOS_GRAVITY_MS2 * ACCELEROMETER_SCALE_RANGE_MAX / measure_range);
            axis_data.axis_z_ = static_cast<std::int32_t>(-gz * IOS_GRAVITY_MS2 * ACCELEROMETER_SCALE_RANGE_MAX / measure_range);
            axis_data.pad_ = 0;

            buffer_.insert(buffer_.end(), reinterpret_cast<std::uint8_t *>(&axis_data),
                           reinterpret_cast<std::uint8_t *>(&axis_data + 1));

            if (++queried_ < desired_) {
                return;
            }

            // Hand the collected packets to the caller outside the lock (the callback takes the
            // kernel lock, so it must not run while ours is held). swap() leaves buffer_ empty for
            // the next request and detaches the data the callback reads from any concurrent reset.
            out.swap(buffer_);
            count = queried_;
            fire = callback_;
            callback_ = nullptr;
            queried_ = 0;
        }

        fire(out, count);
    }

    sensor_ios::sensor_ios(sensor_driver_ios *driver, const sensor_info &info)
        : driver_(driver)
        , info_(info)
        , is_accelerometer_(info.type_ == SENSOR_TYPE_ACCELEROMETER)
        , listening_(false)
        , packet_size_(0)
        , active_accel_measure_range_(0)
        , active_sampling_rate_(1) {
        if (is_accelerometer_) {
            packet_size_ = sizeof(sensor_accelerometer_axis_data);
            sink_ = std::make_shared<accel_sink>();
        } else {
            packet_size_ = 100;
        }
    }

    sensor_ios::~sensor_ios() {
        cancel_data_listening();
    }

    void sensor_ios::start_updates() {
        if (!is_accelerometer_ || !sink_) {
            return;
        }
        // "Gyroscope passthrough" off → behave exactly like the null stub: never feed real data.
        if (!sensor_passthrough_enabled()) {
            return;
        }

        CMMotionManager *manager = (__bridge CMMotionManager *)driver_->motion_manager();
        NSOperationQueue *queue = (__bridge NSOperationQueue *)driver_->delivery_queue();
        if (!manager || !queue || !manager.accelerometerAvailable) {
            return;
        }

        manager.accelerometerUpdateInterval = 1.0 / SAMPLING_RATE_AVAILABLE[active_sampling_rate_];

        std::weak_ptr<accel_sink> weak_sink = sink_;
        [manager startAccelerometerUpdatesToQueue:queue withHandler:^(CMAccelerometerData *data, NSError *error) {
            if (!data) {
                return;
            }
            if (std::shared_ptr<accel_sink> sink = weak_sink.lock()) {
                sink->deliver(data.acceleration.x, data.acceleration.y, data.acceleration.z);
            }
        }];
    }

    void sensor_ios::stop_updates() {
        if (!is_accelerometer_) {
            return;
        }
        CMMotionManager *manager = (__bridge CMMotionManager *)driver_->motion_manager();
        if (manager) {
            [manager stopAccelerometerUpdates];
        }
    }

    bool sensor_ios::get_property(const sensor_property prop, const std::int32_t item_index,
                                  const std::int32_t array_index, sensor_property_data &data) {
        // Global properties (any sensor type).
        switch (prop) {
            case SENSOR_PROPERTY_SAMPLE_RATE:
                if (array_index == -2) {
                    data.set_as_array_status(sensor_property_data::DATA_TYPE_INT, SAMPLING_RATE_MAX_OPTION - 1,
                                             active_sampling_rate_);
                } else {
                    if ((array_index >= SAMPLING_RATE_MAX_OPTION) || (array_index < 0)) {
                        LOG_ERROR(SERVICE_SENSOR, "Trying to get out-of-bound sample rate!");
                        return false;
                    }
                    data.set_int(SAMPLING_RATE_AVAILABLE[array_index]);
                    data.array_index_ = array_index;
                }
                return true;

            default:
                break;
        }

        if (!is_accelerometer_) {
            LOG_ERROR(SERVICE_SENSOR, "Get property unimplemented for iOS sensor type 0x{:X}!", static_cast<int>(info_.type_));
            return false;
        }

        data.property_id_ = prop;

        switch (prop) {
            case SENSOR_PROPERTY_DATA_FORMAT:
                data.set_int(SENSOR_DATA_FORMAT_SCALED);
                break;

            case SENSOR_PROPERTY_SCALED_RANGE:
                data.set_int_range(ACCELEROMETER_SCALE_RANGE_MIN, ACCELEROMETER_SCALE_RANGE_MAX);
                break;

            case SENSOR_PROPERTY_CHANNEL_UNIT:
                data.set_int(SENSOR_UNIT_MS_PER_S2);
                break;

            case SENSOR_PROPERTY_SCALE:
                data.set_int(0);
                break;

            case SENSOR_PROPERTY_MEASURE_RANGE:
                if (array_index == -2) {
                    data.set_as_array_status(sensor_property_data::DATA_TYPE_DOUBLE, ACCELEROMETER_MEASURE_RANGE_MAX_OPTION - 1,
                                             active_accel_measure_range_);
                } else {
                    if ((array_index >= ACCELEROMETER_MEASURE_RANGE_MAX_OPTION) || (array_index < 0)) {
                        LOG_ERROR(SERVICE_SENSOR, "Trying to get out-of-bound measure range!");
                        return false;
                    }
                    data.set_double_range(-ACCELEROMETER_MEASURE_RANGE_AVAILABLE[array_index],
                                          ACCELEROMETER_MEASURE_RANGE_AVAILABLE[array_index]);
                    data.array_index_ = array_index;
                }
                break;

            default:
                LOG_TRACE(SERVICE_SENSOR, "Unhandled getting accelerometer sensor property {}", static_cast<int>(prop));
                break;
        }

        return true;
    }

    bool sensor_ios::set_property(const sensor_property_data &data) {
        switch (data.property_id_) {
            case SENSOR_PROPERTY_SAMPLE_RATE:
                if (data.array_index_ == -2) {
                    if ((data.int_value_ >= SAMPLING_RATE_MAX_OPTION) || (data.int_value_ < 0)) {
                        LOG_ERROR(SERVICE_SENSOR, "Trying to set out-of-bound sample rate!");
                        return false;
                    }
                    active_sampling_rate_ = static_cast<std::uint32_t>(data.int_value_);
                    if (listening_) {
                        // Re-arm CoreMotion at the new rate.
                        stop_updates();
                        start_updates();
                    }
                    return true;
                }
                LOG_ERROR(SERVICE_SENSOR, "Trying to set read-only sample rate property!");
                return false;

            default:
                break;
        }

        if (!is_accelerometer_) {
            LOG_ERROR(SERVICE_SENSOR, "Set property unimplemented for iOS sensor type 0x{:X}!", static_cast<int>(info_.type_));
            return false;
        }

        switch (data.property_id_) {
            case SENSOR_PROPERTY_MEASURE_RANGE:
                if (data.array_index_ == -2) {
                    if ((data.int_value_ >= ACCELEROMETER_MEASURE_RANGE_MAX_OPTION) || (data.int_value_ < 0)) {
                        LOG_ERROR(SERVICE_SENSOR, "Trying to set out-of-bound measure range!");
                        return false;
                    }
                    active_accel_measure_range_ = static_cast<std::uint32_t>(data.int_value_);
                    if (sink_) {
                        sink_->measure_range_index_.store(active_accel_measure_range_, std::memory_order_relaxed);
                    }
                    return true;
                }
                LOG_ERROR(SERVICE_SENSOR, "Trying to set read-only measure range property!");
                return false;

            default:
                LOG_TRACE(SERVICE_SENSOR, "Unhandled setting accelerometer sensor property {}", static_cast<int>(data.property_id_));
                break;
        }

        return false;
    }

    std::vector<sensor_property_data> sensor_ios::get_all_properties(const sensor_property *prop_value) {
        LOG_ERROR(SERVICE_SENSOR, "Get all properties unimplemented for iOS sensor!");
        return std::vector<sensor_property_data>{};
    }

    bool sensor_ios::listen_for_data(std::size_t desired_buffering_count, std::size_t max_buffering_count, std::size_t delay_us) {
        if (listening_) {
            return false;
        }
        if (desired_buffering_count > max_buffering_count) {
            LOG_ERROR(DRIVER_SENSOR, "Desired buffering count is bigger than max buffering count!");
            return false;
        }
        if (desired_buffering_count == 0) {
            desired_buffering_count = max_buffering_count;
        }
        if (desired_buffering_count == 0) {
            desired_buffering_count = 1;
        }

        if (sink_) {
            sink_->desired_ = desired_buffering_count;
        }

        start_updates();
        driver_->track_active_listener(&listening_link_);
        listening_ = true;

        return true;
    }

    bool sensor_ios::cancel_data_listening() {
        if (!listening_) {
            return false;
        }
        stop_updates();
        listening_ = false;
        listening_link_.deque();
        return true;
    }

    void sensor_ios::pause_data_listening() {
        if (!listening_) {
            return;
        }
        stop_updates();
    }

    void sensor_ios::resume_data_listening() {
        if (!listening_) {
            return;
        }
        start_updates();
    }

    void sensor_ios::receive_data(sensor_data_callback callback) {
        if (sink_) {
            sink_->set_request(sink_->desired_, std::move(callback));
        }
    }

    sensor_driver_ios::sensor_driver_ios()
        : motion_manager_(nullptr)
        , delivery_queue_(nullptr)
        , paused_(false) {
        CMMotionManager *manager = [[CMMotionManager alloc] init];
        NSOperationQueue *queue = [[NSOperationQueue alloc] init];
        queue.maxConcurrentOperationCount = 1;   // serialize sample delivery (one accelerometer)
        queue.name = @"com.eka2l1.coremotion";

        motion_manager_ = (void *)CFBridgingRetain(manager);
        delivery_queue_ = (void *)CFBridgingRetain(queue);

        // Expose the same sensor set as the null backend so nothing regresses; only the
        // accelerometer is backed by real CoreMotion data, the rest stay stubs.
        sensor_info info;
        info.location_ = "";

        info.data_type_ = SENSOR_DATA_TYPE_ACCELOREMETER_AXIS;
        info.quantity_ = SENSOR_DATA_QUANTITY_ACCELERATION;
        info.type_ = SENSOR_TYPE_ACCELEROMETER;
        info.id_ = static_cast<std::uint32_t>(infos_.size() + 1);
        info.name_ = "EKA2L1 iOS Accelerometer (CoreMotion)";
        info.vendor_ = "Apple";
        info.item_size_ = sizeof(sensor_accelerometer_axis_data);
        infos_.push_back(info);
        info.item_size_ = 0;

        info.data_type_ = SENSOR_DATA_TYPE_AMBIENT_LIGHT;
        info.quantity_ = SENSOR_DATA_QUANTITY_NOT_USED;
        info.type_ = SENSOR_TYPE_AMBIENT_LIGHT;
        info.id_ = static_cast<std::uint32_t>(infos_.size() + 1);
        info.name_ = "EKA2L1 Ambient Light Sensor Stub";
        info.vendor_ = "Lamp";
        infos_.push_back(info);

        info.data_type_ = SENSOR_DATA_TYPE_MAGNECTIC_NORTH_ANGLE;
        info.quantity_ = SENSOR_DATA_QUANTITY_ANGLE;
        info.type_ = SENSOR_TYPE_MAGNECTIC_NORTH_ANGLE;
        info.id_ = static_cast<std::uint32_t>(infos_.size() + 1);
        info.name_ = "EKA2L1 Magnectic North Angle Stub";
        info.vendor_ = "North Pole";
        infos_.push_back(info);

        info.data_type_ = SENSOR_DATA_TYPE_MAGNEGTOMETER_AXIS;
        info.quantity_ = SENSOR_DATA_QUANTITY_MAGNEGTIC;
        info.type_ = SENSOR_TYPE_MAGNEGTOMETER;
        info.id_ = static_cast<std::uint32_t>(infos_.size() + 1);
        info.name_ = "EKA2L1 Magnegtometer Stub";
        info.vendor_ = "Magnet";
        infos_.push_back(info);

        info.data_type_ = SENSOR_DATA_TYPE_PROXIMOTY;
        info.quantity_ = SENSOR_DATA_QUANTITY_PROXIMOTY;
        info.type_ = SENSOR_TYPE_PROXIMOTY;
        info.id_ = static_cast<std::uint32_t>(infos_.size() + 1);
        info.name_ = "EKA2L1 Proximoty Stub";
        info.vendor_ = "Local restaurant";
        infos_.push_back(info);

        info.data_type_ = SENSOR_DATA_TYPE_ROTATION;
        info.quantity_ = SENSOR_DATA_QUANTITY_ROTATION;
        info.type_ = SENSOR_TYPE_ROTATION;
        info.id_ = static_cast<std::uint32_t>(infos_.size() + 1);
        info.name_ = "EKA2L1 Rotation Stub";
        info.vendor_ = "Football";
        infos_.push_back(info);

        info.data_type_ = SENSOR_DATA_TYPE_ORIENTATION;
        info.quantity_ = SENSOR_DATA_QUANTITY_ORIENTATION;
        info.type_ = SENSOR_TYPE_ORIENTATION;
        info.id_ = static_cast<std::uint32_t>(infos_.size() + 1);
        info.name_ = "EKA2L1 Orientation Stub";
        info.vendor_ = "British";
        infos_.push_back(info);
    }

    sensor_driver_ios::~sensor_driver_ios() {
        while (!listening_list_.empty()) {
            sensor_ios *sensor_obj = E_LOFF(listening_list_.first()->deque(), sensor_ios, listening_link_);
            sensor_obj->cancel_data_listening();
        }

        if (motion_manager_) {
            CMMotionManager *manager = (CMMotionManager *)CFBridgingRelease(motion_manager_);
            [manager stopAccelerometerUpdates];
            manager = nil;
            motion_manager_ = nullptr;
        }
        if (delivery_queue_) {
            NSOperationQueue *queue = (NSOperationQueue *)CFBridgingRelease(delivery_queue_);
            [queue cancelAllOperations];
            queue = nil;
            delivery_queue_ = nullptr;
        }
    }

    std::vector<sensor_info> sensor_driver_ios::queries_active_sensor(const sensor_info &search_info) {
        std::vector<sensor_info> results;
        for (std::size_t i = 0; i < infos_.size(); i++) {
            if (search_info.data_type_ && (search_info.data_type_ != infos_[i].data_type_)) {
                continue;
            }
            if (search_info.quantity_ && (search_info.quantity_ != infos_[i].quantity_)) {
                continue;
            }
            if (search_info.type_ && (search_info.type_ != infos_[i].type_)) {
                continue;
            }
            if (!search_info.name_.empty() && (search_info.name_ != infos_[i].name_)) {
                continue;
            }
            if (!search_info.vendor_.empty() && (search_info.vendor_ != infos_[i].vendor_)) {
                continue;
            }
            results.push_back(infos_[i]);
        }
        return results;
    }

    std::unique_ptr<sensor> sensor_driver_ios::new_sensor_controller(const std::uint32_t id) {
        if ((id == 0) || (id > infos_.size())) {
            return nullptr;
        }

        const sensor_info &basis_info = infos_[id - 1];
        if (basis_info.type_ == SENSOR_TYPE_ACCELEROMETER) {
            return std::make_unique<sensor_ios>(this, basis_info);
        }

        // Everything else is still a no-data stub, matching the previous (null) behaviour.
        return std::make_unique<sensor_accelerometer_null>(basis_info);
    }

    void sensor_driver_ios::track_active_listener(common::double_linked_queue_element *link) {
        listening_list_.push(link);
    }

    bool sensor_driver_ios::pause() {
        if (paused_) {
            return false;
        }
        if (!listening_list_.empty()) {
            common::double_linked_queue_element *first = listening_list_.first();
            common::double_linked_queue_element *end = listening_list_.end();
            do {
                sensor_ios *sensor_obj = E_LOFF(first, sensor_ios, listening_link_);
                sensor_obj->pause_data_listening();
                first = first->next;
            } while (first != end);
        }
        paused_ = true;
        return true;
    }

    bool sensor_driver_ios::resume() {
        if (!paused_) {
            return false;
        }
        if (!listening_list_.empty()) {
            common::double_linked_queue_element *first = listening_list_.first();
            common::double_linked_queue_element *end = listening_list_.end();
            do {
                sensor_ios *sensor_obj = E_LOFF(first, sensor_ios, listening_link_);
                sensor_obj->resume_data_listening();
                first = first->next;
            } while (first != end);
        }
        paused_ = false;
        return true;
    }
}
