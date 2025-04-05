package handlers

import (
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"

	"github.com/reubenmiller/go-c8y/pkg/c8y"
	"github.com/reubenmiller/go-c8y/pkg/microservice"

	"github.com/labstack/echo/v4"
	"github.com/reubenmiller/c8y-devicecert/internal/model"
	"github.com/reubenmiller/c8y-devicecert/pkg/c8yauth"
	certmanager "github.com/reubenmiller/c8y-devicecert/pkg/cert_manager"
)

// RegisterHandlers registers the http handlers to the given echo server
func RegisterCertificateHandlers(e *echo.Echo) {
	e.Add("POST", "/certificates/upload", RegisterDevice, c8yauth.Authorization(c8yauth.RoleSelfSignedCertCreate))
}

func ExternalIdExists(m *microservice.Microservice, tenant string, externalID string) bool {
	// Check for proof that the external id definitely does NOT exist
	_, extResp, _ := m.Client.Identity.GetExternalID(
		m.WithServiceUser(tenant),
		"c8y_Serial",
		externalID,
	)
	return extResp != nil && extResp.StatusCode() == http.StatusOK
}

type ErrorMessage struct {
	Err    string `json:"error"`
	Reason string `json:"reason"`
}

func (e *ErrorMessage) Error() string {
	return e.Err
}

func RegisterDevice(c echo.Context) error {
	cc := c.(*model.RequestContext)

	auth, err := c8yauth.GetUserSecurityContext(c)
	if err != nil {
		return c.JSON(http.StatusForbidden, ErrorMessage{
			Err:    "invalid user context",
			Reason: err.Error(),
		})
	}

	externalID := strings.TrimPrefix(auth.UserID, "device_")

	if externalID == "" {
		slog.Error("Could not derive external name from user.", "userID", auth.UserID)
		return c.JSON(http.StatusUnprocessableEntity, ErrorMessage{
			Err:    "Invalid user id detected in token",
			Reason: "The request must be a device user and not any other type of user",
		})
	}

	// Read certificate
	// var certBuf string
	//
	// err = c.Bind(&certBuf)
	// if err != nil {
	// 	return c.JSON(http.StatusUnprocessableEntity, ErrorMessage{
	// 		Err:    "could not parse body",
	// 		Reason: err.Error(),
	// 	})
	// }

	// publicCert, err := c.FormFile("file")
	// if err != nil {
	// 	return c.JSON(http.StatusUnprocessableEntity, ErrorMessage{
	// 		Err:    "could not file Form Data",
	// 		Reason: err.Error(),
	// 	})
	// }

	// publicCertFile, err := publicCert.Open()
	// if err != nil {
	// 	slog.Error("Failed to open public certificate", "reason", err)
	// 	return err
	// }
	// defer publicCertFile.Close()

	var certBuf strings.Builder
	if _, err := io.Copy(&certBuf, c.Request().Body); err != nil {
		slog.Error("Failed to read public certificate", "reason", err)
		return c.JSON(http.StatusUnprocessableEntity, ErrorMessage{
			Err:    "Failed to read certificate",
			Reason: err.Error(),
		})
	}

	deviceCert, err := certmanager.ParseCertificate(certBuf.String())
	if err != nil {
		slog.Error("Invalid certificate", "reason", err)
		return c.JSON(http.StatusUnprocessableEntity, ErrorMessage{
			Err:    "Invalid certificate",
			Reason: err.Error(),
		})
	}

	if externalID != deviceCert.Subject.CommonName {
		slog.Error("Certificate does not match the token")
		return c.JSON(http.StatusForbidden, map[string]any{
			"error":  "Certificate Common Name and token mismatch",
			"reason": "The certificate's Common Name (CN) does not match the token",
		})
	}

	slog.Info("Uploading device certificate.", "userID", auth.UserID, "tenant", auth.Tenant, "externalID", externalID, "deviceUser", auth.UserID)

	// Add trusted certificate with selective retries, due to current limitation
	// of the sdk which does not subscribe to service user changes
	attempts := 0
	retries := 1
	var cert *c8y.Certificate
	var certResp *c8y.Response

	for attempts <= retries {
		enabled := true
		cert, certResp, err = cc.Microservice.Client.DeviceCertificate.Create(
			cc.Microservice.WithServiceUser(auth.Tenant),
			auth.Tenant,
			&c8y.Certificate{
				Name:                    externalID,
				AutoRegistrationEnabled: &enabled,
				Status:                  c8y.CertificateStatusEnabled,
				CertInPemFormat:         certBuf.String(),
			},
		)

		if err != nil {
			if certResp != nil && certResp.StatusCode() == http.StatusUnauthorized {
				// Transient error
				// Indication that the server user list is out of date and needs to be updated, so
				// update it, then try the request again
				slog.Info("Invalid service user detected, refreshing service users. The next request for the same tenant should then work")
				if err := cc.Microservice.Client.Microservice.SetServiceUsers(); err != nil {
					slog.Error("Could not update microservice service user list.", "err", err)
				}
				err = fmt.Errorf("microservice error. Invalid service user credentials detected for tenant. %s", auth.Tenant)
			} else if certResp != nil && certResp.StatusCode() == http.StatusConflict {
				// Don't retry this error
				slog.Info("Trusted certificate has already been uploaded.", "tenant", auth.Tenant, "externalID", externalID, "deviceUser", auth.UserID)
				return c.JSON(http.StatusConflict, map[string]any{
					"error":  "Certificate has already been uploaded",
					"reason": err.Error(),
				})
			} else {
				// Retry unknown transient errors
				slog.Error("Failed to upload trusted certificate", "reason", err)
				err = fmt.Errorf("certificate upload error. %w", err)
			}
		}

		if retries == 0 {
			break
		}
		attempts += 1
	}

	if err != nil {
		return c.JSON(http.StatusUnprocessableEntity, map[string]any{
			"error":  "Failed to upload trusted certificate",
			"reason": err.Error(),
		})
	}

	// TODO: Remove previous certificate, or should this be done periodically, or
	// let the device decide if it should be deleted to confirm it should be deleted
	slog.Info("Registered device successfully", "response", certResp)

	return c.JSON(http.StatusCreated, map[string]any{
		"status":             "OK",
		"trustedCertificate": cert,
	})
}
