// Package store isola o acesso ao MySQL atrás de uma interface (facilita testes).
package store

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/go-sql-driver/mysql"
)

const mysqlDuplicateEntry = 1062

var ErrEmailExists = errors.New("email já cadastrado")

type User struct {
	ID        int64     `json:"id"`
	Name      string    `json:"name"`
	Email     string    `json:"email"`
	CreatedAt time.Time `json:"created_at"`
}

type Store interface {
	CreateUser(ctx context.Context, name, email, passwordHash string) (User, error)
	ListUsers(ctx context.Context, limit, offset int) ([]User, error)
	Ping(ctx context.Context) error
}

type MySQL struct {
	db *sql.DB
}

func NewMySQL(db *sql.DB) *MySQL { return &MySQL{db: db} }

// Open monta a conexão sem tentar conectar (sql.Open é lazy): a app sobe mesmo com o banco indisponível
// e o /readyz reporta o estado.
func Open(host, port, name, user, password string, maxOpen, maxIdle int) (*sql.DB, error) {
	cfg := mysql.NewConfig()
	cfg.User = user
	cfg.Passwd = password
	cfg.Net = "tcp"
	cfg.Addr = host + ":" + port
	cfg.DBName = name
	cfg.ParseTime = true
	cfg.Loc = time.UTC
	cfg.Timeout = 5 * time.Second
	cfg.ReadTimeout = 5 * time.Second
	cfg.WriteTimeout = 5 * time.Second

	db, err := sql.Open("mysql", cfg.FormatDSN())
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(maxOpen)
	db.SetMaxIdleConns(maxIdle)
	db.SetConnMaxLifetime(5 * time.Minute)
	return db, nil
}

func (m *MySQL) CreateUser(ctx context.Context, name, email, passwordHash string) (User, error) {
	now := time.Now().UTC().Truncate(time.Microsecond)
	res, err := m.db.ExecContext(ctx,
		`INSERT INTO users (name, email, password_hash, created_at) VALUES (?, ?, ?, ?)`,
		name, email, passwordHash, now)
	if err != nil {
		var me *mysql.MySQLError
		if errors.As(err, &me) && me.Number == mysqlDuplicateEntry {
			return User{}, ErrEmailExists
		}
		return User{}, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return User{}, err
	}
	return User{ID: id, Name: name, Email: email, CreatedAt: now}, nil
}

func (m *MySQL) ListUsers(ctx context.Context, limit, offset int) ([]User, error) {
	rows, err := m.db.QueryContext(ctx,
		`SELECT id, name, email, created_at FROM users ORDER BY id LIMIT ? OFFSET ?`, limit, offset)
	if err != nil {
		return nil, err
	}
	// Os erros relevantes de leitura são verificados em rows.Scan e rows.Err() abaixo.
	defer func() { _ = rows.Close() }()

	users := make([]User, 0, limit)
	for rows.Next() {
		var u User
		if err := rows.Scan(&u.ID, &u.Name, &u.Email, &u.CreatedAt); err != nil {
			return nil, err
		}
		users = append(users, u)
	}
	return users, rows.Err()
}

func (m *MySQL) Ping(ctx context.Context) error { return m.db.PingContext(ctx) }
