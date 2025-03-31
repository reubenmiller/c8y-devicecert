package app

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"time"

	"github.com/labstack/echo/v4"
	"github.com/reubenmiller/c8y-devicecert/internal/model"
	"github.com/reubenmiller/c8y-devicecert/pkg/c8yauth"
	"github.com/reubenmiller/c8y-devicecert/pkg/handlers"
	"github.com/reubenmiller/go-c8y/pkg/microservice"
	"go.uber.org/zap"
)

var Mode string

const (
	ModeEnroller   = "enrolment"
	ModeSharedAuth = "sharedauth"
)

// App represents the http server and c8y microservice application
type App struct {
	echoServer      *echo.Echo
	c8ymicroservice *microservice.Microservice
}

// NewApp initializes the microservice with default configuration and registers the microservice
func NewApp() *App {
	app := &App{}
	log.Printf("Application information: Version %s, branch %s, commit %s, buildTime %s", Version, Branch, Commit, BuildTime)

	opts := microservice.Options{}
	opts.AgentInformation = microservice.AgentInformation{
		SerialNumber: Commit,
		Revision:     Version,
		BuildTime:    BuildTime,
	}

	c8ymicroservice := microservice.NewDefaultMicroservice(opts)

	// Set app defaults before registering the microservice
	c8ymicroservice.Config.SetDefault("server.port", "80")

	c8ymicroservice.RegisterMicroserviceAgent()
	app.c8ymicroservice = c8ymicroservice
	return app
}

// Run starts the microservice
func (a *App) Run() {
	application := a.c8ymicroservice
	application.Scheduler.Start()

	if a.echoServer == nil {
		addr := ":" + application.Config.GetString("server.port")
		zap.S().Infof("starting http server on %s", addr)

		a.echoServer = echo.New()
		setDefaultContextHandler(a.echoServer, a.c8ymicroservice)
		provider := c8yauth.NewAuthProvider(application.Client)
		a.echoServer.Use(c8yauth.AuthenticationBasic(provider))
		a.echoServer.Use(c8yauth.AuthenticationBearer(provider))

		a.setRouters()

		ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
		defer stop()
		// Start server
		go func() {
			if err := a.echoServer.Start(addr); err != nil && err != http.ErrServerClosed {
				a.echoServer.Logger.Fatal("shutting down the server")
			}
		}()

		// Wait for interrupt signal to gracefully shutdown the server with a timeout of 10 seconds.
		<-ctx.Done()
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := a.echoServer.Shutdown(ctx); err != nil {
			a.echoServer.Logger.Fatal(err)
		}
	}
}

func setDefaultContextHandler(e *echo.Echo, c8yms *microservice.Microservice) {
	// Add Custom Context
	e.Use(func(h echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			cc := &model.RequestContext{
				Context:      c,
				Microservice: c8yms,
			}
			return h(cc)
		}
	})
}

func (a *App) setRouters() {
	server := a.echoServer

	/*
	 ** Routes
	 */
	handlers.RegisterCertificateHandlers(server)

	/*
	 ** Health endpoints
	 */
	a.c8ymicroservice.AddHealthEndpointHandlers(server)
}
