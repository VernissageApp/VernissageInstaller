enum InstallationStepGuidance {
    static let prerequisites = "This step verifies that the Docker CLI, Docker daemon, and Docker Compose are available. Docker is required to run Vernissage and its supporting service containers."

    static let serverAndDomain = "This step collects the domain for your instance and checks its DNS records and the local availability of ports 80 and 443. This domain becomes the permanent federated identity of the instance. Changing it later can break existing ActivityPub relationships."

    static let administratorAccount = "This step creates and verifies the permanent administrator account after the Vernissage API and Jobs services are running. The account is registered through the API so its password is securely hashed and its ActivityPub key pair is generated. The installer then confirms and approves it, assigns the administrator role, and blocks the temporary admin account for security."

    static let database = "This step configures the PostgreSQL database used for Vernissage accounts, posts, and other persistent application data. We recommend an existing managed PostgreSQL service with automatic backups or snapshots, monitoring, and tested upgrade procedures. A local Docker database uses a persistent named volume, so recreating its container does not delete the data, but that volume remains on this server and is not a backup. A disk or server failure can still cause permanent data loss, so arrange regular off-server backups before using a local database in production."

    static let redis = "This step configures Redis for queues, distributed locks, and cache data. Both an existing service and a local Docker container are suitable because PostgreSQL and S3 remain the sources of persistent application data. Losing Redis does not remove accounts or media, but it can discard pending work such as deliveries or emails, so the local option enables append-only persistence in a Docker volume."

    static let storage = "This step configures the S3-compatible object storage used for Vernissage media. We recommend AWS S3 because it is the most thoroughly tested option and provides managed durability, monitoring, lifecycle rules, and versioning. Other S3-compatible services and local MinIO are self-managed, so verify their backup, recovery, monitoring, security update, and capacity procedures before making the instance public."

    static let serverServices = "This step installs the Vernissage API and background Jobs services from the same versioned server image. The API applies database migrations and serves application requests, while the Jobs service processes queues and scheduled work. Both containers use the database, Redis, and S3 configuration verified in the previous steps."

    static let web = "This step installs the Vernissage Web application and restricts Angular SSR to the instance domain and its subdomains. If media images are served from a different origin, you can optionally add that HTTP or HTTPS origin to the image Content Security Policy. Leave it empty when images use the instance domain."

    static let push = "This step installs the internal Vernissage Push service used to deliver browser notifications. The installer generates a private shared key, gives it to the container, and stores the matching service endpoint and key in PostgreSQL. WebPush remains disabled until you later configure the required VAPID values and enable it in Vernissage settings."

    static let publicAccess = "This step chooses how the instance will be exposed over HTTPS. Development HTTPS uses Caddy's private local certificate authority and requires its root certificate to be trusted on every client device. Production HTTPS uses Caddy and Let's Encrypt and requires public DNS pointing to this server with ports 80 and 443 reachable. Choose the manual option when another proxy, load balancer, CDN, or hosting platform will manage certificates and routing."

    static let proxy = "This step builds and starts the internal Vernissage Nginx proxy that routes API, federation, and machine-readable requests to Vernissage API while sending normal browser traffic to Vernissage Web. When Caddy is selected, Proxy remains private in the Docker network. With manually managed HTTPS, Proxy publishes a host HTTP port for your external TLS terminator."

    static let caddy = "This step completes public HTTPS access. For Development and Production HTTPS it installs Caddy as the TLS terminator, publishes ports 80 and 443, redirects HTTP to HTTPS, and manages certificate renewal. For manually managed HTTPS it leaves the published Proxy endpoint ready for your external proxy, load balancer, CDN, or hosting platform."
}
