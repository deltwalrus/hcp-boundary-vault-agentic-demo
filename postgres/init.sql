-- Vault management user: needs CREATEROLE to provision dynamic DB credentials
CREATE USER vault WITH LOGIN PASSWORD 'vaultpassword' CREATEROLE;

-- Read-only role that Vault's dynamic credentials will inherit
CREATE ROLE incidents_reader;

-- Schema
CREATE TABLE customers (
    id         SERIAL PRIMARY KEY,
    name       VARCHAR(100) NOT NULL,
    email      VARCHAR(150) UNIQUE NOT NULL,
    plan       VARCHAR(50)  NOT NULL DEFAULT 'standard',
    user_count INTEGER      NOT NULL DEFAULT 1,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE incidents (
    id          SERIAL PRIMARY KEY,
    service     VARCHAR(100) NOT NULL,
    status      VARCHAR(20)  NOT NULL DEFAULT 'open',
    started_at  TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    resolved_at TIMESTAMP WITH TIME ZONE,
    description TEXT
);

CREATE TABLE impacted_customers (
    id          SERIAL PRIMARY KEY,
    incident_id INTEGER REFERENCES incidents(id),
    customer_id INTEGER REFERENCES customers(id),
    UNIQUE(incident_id, customer_id)
);

CREATE TABLE support_tickets (
    id          SERIAL PRIMARY KEY,
    customer_id INTEGER REFERENCES customers(id),
    incident_id INTEGER REFERENCES incidents(id),
    subject     VARCHAR(200) NOT NULL,
    status      VARCHAR(20)  NOT NULL DEFAULT 'open',
    created_at  TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Customers (user counts sum to 2915 to match demo narrative)
INSERT INTO customers (name, email, plan, user_count) VALUES
    ('Acme Corporation',   'ops@acme.example.com',           'enterprise',   1200),
    ('Globex Industries',  'it@globex.example.com',           'enterprise',    850),
    ('Initech Solutions',  'admin@initech.example.com',       'professional',  600),
    ('Umbrella Ltd',       'devops@umbrella.example.com',     'professional',  265),
    ('Dunder Mifflin',     'tech@dundermifflin.example.com',  'standard',       85);

-- Active incident: demo-web-app has been down ~18 minutes
INSERT INTO incidents (service, status, started_at, description) VALUES
    ('demo-web-app', 'open', NOW() - INTERVAL '18 minutes',
     'Health check failing on demo-web-app. Service unreachable — startup failure suspected.');

-- 4 enterprise/professional customers are impacted
INSERT INTO impacted_customers (incident_id, customer_id)
SELECT 1, id FROM customers
WHERE name IN ('Acme Corporation', 'Globex Industries', 'Initech Solutions', 'Umbrella Ltd');

-- 4 open support tickets (one per impacted customer)
INSERT INTO support_tickets (customer_id, incident_id, subject, status) VALUES
    (1, 1, 'Platform unreachable — business-critical workflows blocked',    'open'),
    (2, 1, 'All users receiving connection refused errors',                 'open'),
    (3, 1, 'Service down — SLA breach imminent (15-min window remaining)',  'open'),
    (4, 1, 'Unable to access application — escalating to account team',    'open');

-- Grant read-only access to the incidents_reader role
GRANT CONNECT ON DATABASE incidents TO incidents_reader;
GRANT USAGE ON SCHEMA public TO incidents_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO incidents_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO incidents_reader;

-- Let vault create dynamic roles that inherit incidents_reader.
-- WITH ADMIN OPTION is required: Postgres denies GRANT of a role to a third
-- party unless the granting role holds admin on it, not just membership.
-- Without this, Vault's dynamic-credential creation fails with
-- "permission denied to grant role \"incidents_reader\"" (SQLSTATE 42501).
GRANT incidents_reader TO vault WITH ADMIN OPTION;
