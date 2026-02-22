-- ============================================================
-- Diploma Project: Spatially-Aware IoT Ambient Lighting System
-- Database Schema v1.0
-- PostgreSQL 16 / Flyway Migration
-- ============================================================
-- V1__initial_schema.sql

-- ============================================================
-- 1. ROOM LAYOUT
-- Represents a physical room where LED strips are installed.
-- Users can have multiple rooms, each with its own floor plan.
-- ============================================================
CREATE TABLE room_layout (
    id              BIGSERIAL PRIMARY KEY,
    name            VARCHAR(100)    NOT NULL,
    description     VARCHAR(500),
    floor_plan_url  VARCHAR(500),           -- URL/path to uploaded floor plan image
    width_cm        INTEGER         NOT NULL DEFAULT 500,   -- room width in centimeters (for coordinate scaling)
    height_cm       INTEGER         NOT NULL DEFAULT 400,   -- room height in centimeters
    latitude        DOUBLE PRECISION,       -- for circadian sun position calculation
    longitude       DOUBLE PRECISION,       -- for circadian sun position calculation
    created_at      TIMESTAMP       NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP       NOT NULL DEFAULT NOW()
);

-- ============================================================
-- 2. DEVICE
-- Represents a physical ESP32 controller node.
-- Auto-registered via MQTT discovery or manually added.
-- ============================================================
CREATE TABLE device (
    id              BIGSERIAL PRIMARY KEY,
    mac_address     VARCHAR(17)     NOT NULL UNIQUE,    -- e.g., "AA:BB:CC:DD:EE:FF"
    name            VARCHAR(100)    NOT NULL DEFAULT 'Unnamed Device',
    firmware_version VARCHAR(20),
    ip_address      VARCHAR(45),                        -- last known IP (IPv4 or IPv6)
    status          VARCHAR(20)     NOT NULL DEFAULT 'OFFLINE',  -- ONLINE, OFFLINE, ERROR
    last_seen_at    TIMESTAMP,
    has_microphone  BOOLEAN         NOT NULL DEFAULT FALSE,      -- does this node have INMP441?
    current_mode    VARCHAR(20)     NOT NULL DEFAULT 'NORMAL',   -- NORMAL, AUDIO, STREAM
    room_id         BIGINT          REFERENCES room_layout(id) ON DELETE SET NULL,
    created_at      TIMESTAMP       NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP       NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_device_mac ON device(mac_address);
CREATE INDEX idx_device_room ON device(room_id);
CREATE INDEX idx_device_status ON device(status);

-- ============================================================
-- 3. LED STRIP
-- Represents a single LED strip (or segment) connected to a device.
-- One device can drive multiple strips (via different GPIO pins).
-- Stores 2D spatial coordinates for the spatial mapping engine.
-- ============================================================
CREATE TABLE led_strip (
    id              BIGSERIAL PRIMARY KEY,
    device_id       BIGINT          NOT NULL REFERENCES device(id) ON DELETE CASCADE,
    name            VARCHAR(100)    NOT NULL DEFAULT 'Strip 1',
    gpio_pin        INTEGER         NOT NULL DEFAULT 18,         -- ESP32 GPIO data pin
    led_count       INTEGER         NOT NULL DEFAULT 60,         -- number of LEDs on this strip
    segment_start   INTEGER         NOT NULL DEFAULT 0,          -- first LED index (for multi-strip on same GPIO)
    segment_end     INTEGER         NOT NULL DEFAULT 59,         -- last LED index

    -- Spatial coordinates (2D position on room map, in centimeters from top-left origin)
    pos_x           DOUBLE PRECISION NOT NULL DEFAULT 0.0,       -- X position on room map
    pos_y           DOUBLE PRECISION NOT NULL DEFAULT 0.0,       -- Y position on room map
    orientation     DOUBLE PRECISION NOT NULL DEFAULT 0.0,       -- angle in degrees (0 = horizontal right)
    length_cm       DOUBLE PRECISION NOT NULL DEFAULT 100.0,     -- physical length of strip

    -- Circadian spatial gradient
    window_distance DOUBLE PRECISION NOT NULL DEFAULT 1.0,       -- distance to nearest window (0.0 = at window, 1.0 = far from window)
                                                                  -- used for circadian gradient: lower = cooler temp, higher = warmer temp

    room_id         BIGINT          REFERENCES room_layout(id) ON DELETE SET NULL,
    created_at      TIMESTAMP       NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP       NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_strip_device ON led_strip(device_id);
CREATE INDEX idx_strip_room ON led_strip(room_id);
CREATE INDEX idx_strip_position ON led_strip(pos_x, pos_y);   -- for spatial queries

-- ============================================================
-- 4. SPATIAL ZONE
-- Named zones on the room map (e.g., "Desk Area", "TV Wall").
-- Optional: allows grouping strips by functional area.
-- ============================================================
CREATE TABLE spatial_zone (
    id              BIGSERIAL PRIMARY KEY,
    room_id         BIGINT          NOT NULL REFERENCES room_layout(id) ON DELETE CASCADE,
    name            VARCHAR(100)    NOT NULL,
    center_x        DOUBLE PRECISION NOT NULL,
    center_y        DOUBLE PRECISION NOT NULL,
    radius          DOUBLE PRECISION NOT NULL DEFAULT 100.0,     -- zone radius in cm
    color_hex       VARCHAR(7),                                   -- default zone color, e.g. "#FF5500"
    created_at      TIMESTAMP       NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_zone_room ON spatial_zone(room_id);

-- ============================================================
-- 5. CIRCADIAN PROFILE
-- Configuration for circadian spatial gradients per room.
-- Stores the temperature range and schedule.
-- ============================================================
CREATE TABLE circadian_profile (
    id              BIGSERIAL PRIMARY KEY,
    room_id         BIGINT          NOT NULL UNIQUE REFERENCES room_layout(id) ON DELETE CASCADE,
    enabled         BOOLEAN         NOT NULL DEFAULT FALSE,
    warm_temp_kelvin INTEGER        NOT NULL DEFAULT 2700,       -- warmest color temp (evening)
    cool_temp_kelvin INTEGER        NOT NULL DEFAULT 6500,       -- coolest color temp (midday)
    window_weight   DOUBLE PRECISION NOT NULL DEFAULT 0.5,       -- how much windowDistance affects the gradient (0.0-1.0)
    transition_minutes INTEGER      NOT NULL DEFAULT 30,         -- fade duration when switching
    created_at      TIMESTAMP       NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP       NOT NULL DEFAULT NOW()
);

-- ============================================================
-- 6. AUDIO PROFILE
-- Configuration for spatial audio reactivity per room.
-- Defines how frequency bands map to spatial positions.
-- ============================================================
CREATE TABLE audio_profile (
    id              BIGSERIAL PRIMARY KEY,
    room_id         BIGINT          NOT NULL UNIQUE REFERENCES room_layout(id) ON DELETE CASCADE,
    enabled         BOOLEAN         NOT NULL DEFAULT FALSE,
    source_device_id BIGINT         REFERENCES device(id) ON DELETE SET NULL,   -- which ESP32 has the mic
    mode            VARCHAR(20)     NOT NULL DEFAULT 'STEREO',   -- STEREO (L/R), RIPPLE, FREQUENCY_ZONES
    bass_zone_x     DOUBLE PRECISION,       -- where bass frequencies are mapped
    bass_zone_y     DOUBLE PRECISION,
    treble_zone_x   DOUBLE PRECISION,       -- where treble frequencies are mapped
    treble_zone_y   DOUBLE PRECISION,
    sensitivity     DOUBLE PRECISION NOT NULL DEFAULT 0.7,       -- 0.0 to 1.0
    created_at      TIMESTAMP       NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP       NOT NULL DEFAULT NOW()
);

-- ============================================================
-- 7. PRESET
-- Saved lighting presets (Gaming, Relax, Focus, Movie, etc.)
-- ============================================================
CREATE TABLE preset (
    id              BIGSERIAL PRIMARY KEY,
    room_id         BIGINT          NOT NULL REFERENCES room_layout(id) ON DELETE CASCADE,
    name            VARCHAR(100)    NOT NULL,
    mode            VARCHAR(20)     NOT NULL DEFAULT 'MANUAL',   -- MANUAL, AUDIO, CIRCADIAN, MOVIE
    config_json     JSONB           NOT NULL DEFAULT '{}',       -- flexible config storage
    is_default      BOOLEAN         NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMP       NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_preset_room ON preset(room_id);

-- ============================================================
-- 8. COMMAND LOG (optional, for debugging and thesis metrics)
-- Logs every spatial command sent for latency analysis.
-- ============================================================
CREATE TABLE command_log (
    id              BIGSERIAL PRIMARY KEY,
    room_id         BIGINT          REFERENCES room_layout(id) ON DELETE SET NULL,
    command_type    VARCHAR(30)     NOT NULL,    -- SPATIAL_CLICK, AUDIO_UPDATE, CIRCADIAN_SHIFT, MODE_SWITCH
    payload_json    JSONB,
    strips_affected INTEGER         NOT NULL DEFAULT 0,
    processing_ms   DOUBLE PRECISION,           -- backend processing time
    total_latency_ms DOUBLE PRECISION,          -- end-to-end latency (if measurable)
    created_at      TIMESTAMP       NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_cmdlog_room ON command_log(room_id);
CREATE INDEX idx_cmdlog_type ON command_log(command_type);
CREATE INDEX idx_cmdlog_created ON command_log(created_at);
