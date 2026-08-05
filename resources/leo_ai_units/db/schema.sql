-- SQL schema for AI units persistence

CREATE TABLE IF NOT EXISTS `incidents_units` (
    `id` INT AUTO_INCREMENT PRIMARY KEY,
    `unit_id` INT NOT NULL,
    `incident_id` INT NOT NULL,
    `unit_type` VARCHAR(64),
    `ped_model` VARCHAR(128),
    `vehicle_model` VARCHAR(128),
    `host` INT,
    `net_id` VARCHAR(64),
    `status` VARCHAR(64),
    `spawned_at` TIMESTAMP NULL DEFAULT NULL,
    `despawned_at` TIMESTAMP NULL DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
