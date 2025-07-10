const PRIORITY_BASE_INCREMENT = 64;

const Thread = struct {
    process: *Process,

    global_id: u64, // caché au process, monotone, pas de recyclage
    local_id: u32, // monotone, pas de recyclage

    // Scheduler options

    cooperation_ratio: f32, // entre 0.1 (pas coop) et 1.0 (coop max) [default: 0.2]
    dynamic_priority: u32, // priorité calculée à chaque cycle

    pub fn update_priority(self: *@This()) void {
        self.dynamic_priority += PRIORITY_BASE_INCREMENT * (self.process.importance * self.cooperation_ratio + 1);
    }
};

const Process = struct {
    id: u64,

    max_alive_threads: u16, // default = 2 * core_num

    // Scheduler options

    importance: f32, // facteur > 0, 1.0 par défaut, max 8.0, déterminée par l'OS et l'utilisateur
};
