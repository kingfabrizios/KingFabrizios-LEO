-- SQL schema for leo_dispatch

CREATE TABLE IF NOT EXISTS `incidents` (
    `id` INT AUTO_INCREMENT PRIMARY KEY,
    `incident_id` INT NOT NULL,
    `type` VARCHAR(64) NOT NULL,
    `detail` TEXT,
    `x` DOUBLE,
    `y` DOUBLE,
    `z` DOUBLE,
    `status` VARCHAR(32),
    `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
