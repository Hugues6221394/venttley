-- ============================================================================
-- Vently | Initial Schema Migration
-- Anonymous social platform for Gen Z emotional expression and peer support.
-- Zero-PII by design. Uses ltree for high-speed comment tree traversal.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "ltree";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ---------------------------------------------------------------------------
-- Enumerated types
-- ---------------------------------------------------------------------------
DO $$ BEGIN
    CREATE TYPE user_role_type AS ENUM ('normal', 'plug', 'super_admin');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE mood_badge_type AS ENUM (
        'sad', 'lonely', 'angry', 'confused', 'happy', 'healing', 'broken', 'hopeful',
        'exhausted', 'overthinking', 'anxious', 'grateful'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE safety_tier_type AS ENUM ('restricted_minor', 'standard');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ---------------------------------------------------------------------------
-- Users  (zero personally identifiable information)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS users (
    user_id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    anonymous_pseudonym  VARCHAR(100) NOT NULL,
    avatar_seed          VARCHAR(100) NOT NULL,
    current_mood         mood_badge_type DEFAULT 'healing' NOT NULL,
    user_role            user_role_type  DEFAULT 'normal'  NOT NULL,
    is_verified          BOOLEAN         DEFAULT FALSE     NOT NULL,
    account_status       VARCHAR(20)     DEFAULT 'active'
                         CHECK (account_status IN ('active', 'suspended', 'restricted')),
    safety_tier          safety_tier_type DEFAULT 'standard' NOT NULL,
    birth_year           SMALLINT,                         -- year only, no day/month stored
    recovery_key_hash    TEXT NOT NULL,                    -- argon2id hash of client recovery key
    device_signature_hash TEXT,                            -- argon2id hash of hardware signature
    public_key           TEXT,                             -- E2EE identity key (curve25519)
    created_at           TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at           TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT recovery_key_hash_len CHECK (length(recovery_key_hash) > 0)
);

CREATE INDEX IF NOT EXISTS idx_users_pseudonym ON users(anonymous_pseudonym);
CREATE INDEX IF NOT EXISTS idx_users_role ON users(user_role) WHERE user_role <> 'normal';

-- ---------------------------------------------------------------------------
-- Plug profiles (verified community keepers, super-admin approved)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS plug_profiles (
    plug_id              UUID PRIMARY KEY REFERENCES users(user_id) ON DELETE CASCADE,
    display_name         VARCHAR(50) NOT NULL UNIQUE,
    bio                  VARCHAR(160),
    location_label       VARCHAR(80),
    tribe_count          INT DEFAULT 0 CHECK (tribe_count >= 0),
    approved_by_super_admin_id UUID REFERENCES users(user_id) ON DELETE SET NULL,
    approved_at          TIMESTAMP WITH TIME ZONE,
    created_at           TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL
);

-- ---------------------------------------------------------------------------
-- Tribes follow framework (composite PK prevents duplicate follows)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tribes_follows (
    follower_id          UUID REFERENCES users(user_id)        ON DELETE CASCADE NOT NULL,
    plug_id              UUID REFERENCES plug_profiles(plug_id) ON DELETE CASCADE NOT NULL,
    created_at           TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
    PRIMARY KEY (follower_id, plug_id)
);

-- ---------------------------------------------------------------------------
-- Spaces (campus, city, interest group)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS spaces (
    space_id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    space_name           VARCHAR(100) NOT NULL UNIQUE,
    space_type           VARCHAR(20) DEFAULT 'campus'
                         CHECK (space_type IN ('campus', 'city', 'interest_group')),
    description          VARCHAR(280),
    domain_validation    VARCHAR(100),                     -- e.g. 'ur.ac.rw'
    member_count         INT DEFAULT 0 CHECK (member_count >= 0),
    created_at           TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL
);

CREATE TABLE IF NOT EXISTS space_memberships (
    space_id             UUID REFERENCES spaces(space_id) ON DELETE CASCADE NOT NULL,
    user_id              UUID REFERENCES users(user_id)   ON DELETE CASCADE NOT NULL,
    joined_at            TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
    PRIMARY KEY (space_id, user_id)
);

-- ---------------------------------------------------------------------------
-- Posts (confessions, testimonies, plug prompts)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS posts (
    post_id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    author_id            UUID REFERENCES users(user_id)   ON DELETE SET NULL,
    space_id             UUID REFERENCES spaces(space_id) ON DELETE CASCADE,
    category_name        VARCHAR(50) NOT NULL CHECK (category_name IN (
        'confessions', 'testimonies', 'relationships', 'family_issues', 'mental_health',
        'campus_life', 'adulting', 'regrets', 'trauma', 'friendship', 'faith_spirituality',
        'questions', 'secrets', 'vent_zone', 'dark_thoughts', 'funny_confessions',
        'dreams_goals', 'hot_takes', 'late_night', 'healing_corner'
    )),
    post_type            VARCHAR(20) DEFAULT 'user_post'
                         CHECK (post_type IN ('user_post', 'plug_prompt')),
    content              TEXT NOT NULL CHECK (length(content) <= 1000),
    post_mood            mood_badge_type NOT NULL,
    is_audio             BOOLEAN DEFAULT FALSE NOT NULL,
    audio_url            VARCHAR(512),
    audio_duration_ms    INT,
    is_approved          BOOLEAN DEFAULT TRUE,             -- open community mode default
    likes_count          INT DEFAULT 0 CHECK (likes_count   >= 0),
    comments_count       INT DEFAULT 0 CHECK (comments_count >= 0),
    created_at           TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
    deleted_at           TIMESTAMP WITH TIME ZONE
);

-- ---------------------------------------------------------------------------
-- Polls
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS post_polls (
    poll_id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    post_id              UUID REFERENCES posts(post_id) ON DELETE CASCADE NOT NULL,
    question             TEXT NOT NULL,
    closes_at            TIMESTAMP WITH TIME ZONE NOT NULL,
    created_at           TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL
);

CREATE TABLE IF NOT EXISTS poll_options (
    option_id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    poll_id              UUID REFERENCES post_polls(poll_id) ON DELETE CASCADE NOT NULL,
    option_text          VARCHAR(100) NOT NULL
);

CREATE TABLE IF NOT EXISTS poll_votes (
    vote_id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    poll_id              UUID REFERENCES post_polls(poll_id)   ON DELETE CASCADE NOT NULL,
    option_id            UUID REFERENCES poll_options(option_id) ON DELETE CASCADE NOT NULL,
    user_id              UUID REFERENCES users(user_id)         ON DELETE CASCADE NOT NULL,
    created_at           TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
    UNIQUE(poll_id, user_id)
);

-- ---------------------------------------------------------------------------
-- Likes & saves
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS post_likes (
    like_id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    post_id              UUID REFERENCES posts(post_id) ON DELETE CASCADE NOT NULL,
    user_id              UUID REFERENCES users(user_id) ON DELETE CASCADE NOT NULL,
    created_at           TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
    UNIQUE(post_id, user_id)
);

CREATE TABLE IF NOT EXISTS post_saves (
    save_id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    post_id              UUID REFERENCES posts(post_id) ON DELETE CASCADE NOT NULL,
    user_id              UUID REFERENCES users(user_id) ON DELETE CASCADE NOT NULL,
    created_at           TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
    UNIQUE(post_id, user_id)
);

-- ---------------------------------------------------------------------------
-- Threaded comments using ltree materialized paths
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS posts_comments (
    comment_id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    post_id              UUID REFERENCES posts(post_id) ON DELETE CASCADE NOT NULL,
    parent_id            UUID REFERENCES posts_comments(comment_id) ON DELETE CASCADE,
    author_id            UUID REFERENCES users(user_id) ON DELETE SET NULL,
    content              TEXT NOT NULL CHECK (length(content) <= 500),
    path                 ltree NOT NULL,
    likes_count          INT DEFAULT 0 CHECK (likes_count >= 0),
    created_at           TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
    deleted_at           TIMESTAMP WITH TIME ZONE
);

CREATE TABLE IF NOT EXISTS comment_likes (
    comment_id           UUID REFERENCES posts_comments(comment_id) ON DELETE CASCADE NOT NULL,
    user_id              UUID REFERENCES users(user_id)              ON DELETE CASCADE NOT NULL,
    created_at           TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
    PRIMARY KEY (comment_id, user_id)
);

-- ---------------------------------------------------------------------------
-- Chat (E2EE message requests + double-ratchet payloads)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS chat_rooms (
    room_id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    initiated_by         UUID REFERENCES users(user_id) ON DELETE SET NULL,
    received_by          UUID REFERENCES users(user_id) ON DELETE SET NULL,
    origin_post_id       UUID REFERENCES posts(post_id) ON DELETE SET NULL,
    request_preview      VARCHAR(280),                     -- short, plaintext intro from sender
    room_status          VARCHAR(20) DEFAULT 'pending_request'
                         CHECK (room_status IN ('pending_request', 'active', 'declined', 'blocked')),
    created_at           TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at           TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL
);

CREATE TABLE IF NOT EXISTS chat_messages (
    message_id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    room_id              UUID REFERENCES chat_rooms(room_id) ON DELETE CASCADE NOT NULL,
    sender_id            UUID REFERENCES users(user_id) ON DELETE SET NULL,
    encrypted_payload    TEXT NOT NULL,
    nonce_iv             VARCHAR(64) NOT NULL,
    ratchet_header       TEXT,                             -- double-ratchet metadata
    delivered_at         TIMESTAMP WITH TIME ZONE,
    read_at              TIMESTAMP WITH TIME ZONE,
    created_at           TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL
);

-- ---------------------------------------------------------------------------
-- Blocks & moderation
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS user_blocks (
    block_id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    blocker_id           UUID REFERENCES users(user_id) ON DELETE CASCADE NOT NULL,
    blocked_id           UUID REFERENCES users(user_id) ON DELETE CASCADE NOT NULL,
    created_at           TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
    UNIQUE(blocker_id, blocked_id),
    CHECK (blocker_id <> blocked_id)
);

CREATE TABLE IF NOT EXISTS moderation_reports (
    report_id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    reporter_id          UUID REFERENCES users(user_id)            ON DELETE SET NULL,
    target_post_id       UUID REFERENCES posts(post_id)            ON DELETE CASCADE,
    target_comment_id    UUID REFERENCES posts_comments(comment_id) ON DELETE CASCADE,
    target_room_id       UUID REFERENCES chat_rooms(room_id)        ON DELETE CASCADE,
    report_category      VARCHAR(30) NOT NULL CHECK (report_category IN (
        'harassment', 'hate_speech', 'self_harm', 'doxxing', 'spam', 'explicit'
    )),
    context_data         TEXT,
    is_resolved          BOOLEAN DEFAULT FALSE,
    resolved_by          UUID REFERENCES users(user_id) ON DELETE SET NULL,
    resolved_at          TIMESTAMP WITH TIME ZONE,
    created_at           TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL
);

-- ---------------------------------------------------------------------------
-- Question of the day prompts (issued by Plugz)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS plug_prompts (
    prompt_id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    plug_id              UUID REFERENCES plug_profiles(plug_id) ON DELETE CASCADE NOT NULL,
    prompt_text          VARCHAR(280) NOT NULL,
    answers_count        INT DEFAULT 0 CHECK (answers_count >= 0),
    is_active            BOOLEAN DEFAULT TRUE,
    created_at           TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL
);

CREATE TABLE IF NOT EXISTS prompt_answers (
    answer_id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    prompt_id            UUID REFERENCES plug_prompts(prompt_id) ON DELETE CASCADE NOT NULL,
    author_id            UUID REFERENCES users(user_id)          ON DELETE SET NULL,
    answer_text          VARCHAR(500) NOT NULL,
    created_at           TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL
);

-- ---------------------------------------------------------------------------
-- Notifications inbox
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS notifications (
    notification_id      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id              UUID REFERENCES users(user_id) ON DELETE CASCADE NOT NULL,
    kind                 VARCHAR(40) NOT NULL CHECK (kind IN (
        'comment_reply', 'post_like', 'comment_like', 'new_follower',
        'message_request', 'message_accepted', 'tribe_prompt', 'moderation_action'
    )),
    payload              JSONB NOT NULL DEFAULT '{}'::jsonb,
    is_read              BOOLEAN DEFAULT FALSE,
    created_at           TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL
);

-- ---------------------------------------------------------------------------
-- Performance indexes
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_posts_category_created  ON posts(category_name, created_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_posts_space_created     ON posts(space_id, created_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_posts_author_created    ON posts(author_id, created_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_posts_mood              ON posts(post_mood) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_comments_path_gist      ON posts_comments USING GIST(path);
CREATE INDEX IF NOT EXISTS idx_comments_post_created   ON posts_comments(post_id, created_at ASC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_chat_rooms_users        ON chat_rooms(initiated_by, received_by);
CREATE INDEX IF NOT EXISTS idx_chat_rooms_status       ON chat_rooms(received_by, room_status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_chat_messages_room      ON chat_messages(room_id, created_at ASC);
CREATE INDEX IF NOT EXISTS idx_reports_status          ON moderation_reports(is_resolved, created_at ASC);
CREATE INDEX IF NOT EXISTS idx_tribes_follows_plug     ON tribes_follows(plug_id, follower_id);
CREATE INDEX IF NOT EXISTS idx_notifications_user      ON notifications(user_id, is_read, created_at DESC);

-- ---------------------------------------------------------------------------
-- Triggers: maintain denormalized counts atomically
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_inc_likes() RETURNS TRIGGER AS $$
BEGIN
    UPDATE posts SET likes_count = likes_count + 1 WHERE post_id = NEW.post_id;
    RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION trg_dec_likes() RETURNS TRIGGER AS $$
BEGIN
    UPDATE posts SET likes_count = GREATEST(likes_count - 1, 0) WHERE post_id = OLD.post_id;
    RETURN OLD;
END; $$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS post_likes_inc ON post_likes;
DROP TRIGGER IF EXISTS post_likes_dec ON post_likes;
CREATE TRIGGER post_likes_inc AFTER INSERT ON post_likes FOR EACH ROW EXECUTE FUNCTION trg_inc_likes();
CREATE TRIGGER post_likes_dec AFTER DELETE ON post_likes FOR EACH ROW EXECUTE FUNCTION trg_dec_likes();

CREATE OR REPLACE FUNCTION trg_inc_comments() RETURNS TRIGGER AS $$
BEGIN
    UPDATE posts SET comments_count = comments_count + 1 WHERE post_id = NEW.post_id;
    RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION trg_dec_comments() RETURNS TRIGGER AS $$
BEGIN
    UPDATE posts SET comments_count = GREATEST(comments_count - 1, 0) WHERE post_id = OLD.post_id;
    RETURN OLD;
END; $$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS comments_inc ON posts_comments;
DROP TRIGGER IF EXISTS comments_dec ON posts_comments;
CREATE TRIGGER comments_inc AFTER INSERT ON posts_comments FOR EACH ROW EXECUTE FUNCTION trg_inc_comments();
CREATE TRIGGER comments_dec AFTER DELETE ON posts_comments FOR EACH ROW EXECUTE FUNCTION trg_dec_comments();

CREATE OR REPLACE FUNCTION trg_inc_tribe_count() RETURNS TRIGGER AS $$
BEGIN
    UPDATE plug_profiles SET tribe_count = tribe_count + 1 WHERE plug_id = NEW.plug_id;
    RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION trg_dec_tribe_count() RETURNS TRIGGER AS $$
BEGIN
    UPDATE plug_profiles SET tribe_count = GREATEST(tribe_count - 1, 0) WHERE plug_id = OLD.plug_id;
    RETURN OLD;
END; $$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS tribes_follows_inc ON tribes_follows;
DROP TRIGGER IF EXISTS tribes_follows_dec ON tribes_follows;
CREATE TRIGGER tribes_follows_inc AFTER INSERT ON tribes_follows FOR EACH ROW EXECUTE FUNCTION trg_inc_tribe_count();
CREATE TRIGGER tribes_follows_dec AFTER DELETE ON tribes_follows FOR EACH ROW EXECUTE FUNCTION trg_dec_tribe_count();

-- ---------------------------------------------------------------------------
-- RPC helpers
-- ---------------------------------------------------------------------------
-- Insert a comment, computing its ltree path from parent automatically.
CREATE OR REPLACE FUNCTION create_threaded_comment(
    p_post_id    UUID,
    p_parent_id  UUID,
    p_author_id  UUID,
    p_content    TEXT
) RETURNS UUID AS $$
DECLARE
    new_id  UUID := uuid_generate_v4();
    new_lbl TEXT := replace(new_id::text, '-', '');
    parent_path ltree;
    new_path ltree;
BEGIN
    IF p_parent_id IS NULL THEN
        new_path := text2ltree(new_lbl);
    ELSE
        SELECT path INTO parent_path
        FROM posts_comments WHERE comment_id = p_parent_id;
        IF parent_path IS NULL THEN
            RAISE EXCEPTION 'parent comment not found';
        END IF;
        new_path := parent_path || text2ltree(new_lbl);
    END IF;

    INSERT INTO posts_comments(comment_id, post_id, parent_id, author_id, content, path)
    VALUES (new_id, p_post_id, p_parent_id, p_author_id, p_content, new_path);

    RETURN new_id;
END; $$ LANGUAGE plpgsql;

-- Fetch a full comment tree for a post in chronological-clustered order.
CREATE OR REPLACE FUNCTION fetch_comment_tree(p_post_id UUID)
RETURNS TABLE (
    comment_id  UUID,
    parent_id   UUID,
    author_id   UUID,
    content     TEXT,
    path        ltree,
    depth       INT,
    likes_count INT,
    created_at  TIMESTAMPTZ
) AS $$
    SELECT comment_id, parent_id, author_id, content, path,
           (nlevel(path) - 1) AS depth,
           likes_count, created_at
    FROM   posts_comments
    WHERE  post_id = p_post_id
      AND  deleted_at IS NULL
    ORDER BY path ASC, created_at ASC;
$$ LANGUAGE sql STABLE;
