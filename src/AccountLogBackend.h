#pragma once

#include <QJsonObject>
#include <QHash>
#include <QString>
#include <QThreadPool>

#include <atomic>
#include <functional>

#include "rep_accountlog_ui_source.h"
#include "logos_ui_plugin_context.h"

struct LogosAccountCore;

// The account log backend.
//
// It decides nothing. Every account question -- what the vault holds, what the
// log says, whether an edit is legal, what a publish writes -- is answered by
// the linked-in Rust library, and this class marshals: JSON in from the
// library, properties out to the view, the view's strings back in.
//
// It is a `ui_qml` backend, so the runtime hands it no data directory the way
// it hands a core module `instance_persistence_path`. The vault path is
// therefore this app's own choice, and `vaultDirectory()` is where that choice
// lives.
//
// Threading: the two calls that reach the store take as long as the store
// takes, and a slot that blocks here blocks the view behind it. So every call
// runs on a one-thread pool and comes back through the event loop, and `busy`
// is what the view guards its buttons with.
class AccountLogBackend : public AccountLogSimpleSource,
                          public LogosUiPluginContext
{
public:
    AccountLogBackend();
    ~AccountLogBackend() override;

    void refresh() override;
    void selectAccount(QString address) override;
    void createAccount(QString password) override;
    void importAccount(QString secretHex, QString password) override;
    void exportAccount(QString address, QString password) override;
    void forgetAccount(QString address) override;
    void observeAccount(QString address) override;
    void stopObserving(QString address) override;
    void stageAddInstallation(QString keyHex) override;
    void stageSetDisplayName(QString name) override;
    void stageRevoke(int index) override;
    void discardPending() override;
    void publish(QString password) override;
    void dismissNotice() override;

    /// Where this app keeps account keys. `LOGOS_ACCOUNTLOG_VAULT_DIR` if it is
    /// set, otherwise a directory of our own naming under the generic data
    /// location -- never the host's application data, whose name belongs to
    /// whichever process happens to be hosting the view.
    static QString vaultDirectory();
    /// `LOGOS_ACCOUNTLOG_STORE_URL` if it is set, otherwise the library's own
    /// default. The literal "memory" runs against an in-process store. Named
    /// apart from the `storeUrl` property, which the replica reads and which
    /// this is the source of.
    static QString configuredStoreUrl();

protected:
    void onContextReady() override;

private:
    /// One library call, off the view's thread. `what` names the call for the
    /// `failed` and `succeeded` signals; `work` runs on the pool, and returns
    /// null for a call no longer wanted, which then ends without a word;
    /// `landed` runs on this object's thread with the parsed reply when it
    /// said ok, and `refused` with the message when it did not.
    void call(const QString &what,
              std::function<char *(LogosAccountCore *)> work,
              std::function<void(const QJsonObject &)> landed = {},
              std::function<void(const QString &)> refused = {});

    /// Re-read the vault listing into `accountsJson`, and select the first
    /// account when nothing is selected yet.
    void reloadAccounts();
    /// Re-read `stateJson` for the selected account. Reads no store.
    void reloadState();
    /// Put `address` on screen. The one way the selection changes, so what
    /// described the last account (its notice, its just-published marks) goes
    /// with it.
    void setSelection(const QString &address);
    /// After a staged edit lands: the list and the state are drawn again.
    void edited();

    void setNotice(const QString &kind, const QString &title, const QString &body);
    void report(const QString &what, const QString &message);

    LogosAccountCore *m_core = nullptr;
    /// One thread, so two calls never run against the library at once and the
    /// order the person pressed things in is the order they happen in.
    QThreadPool m_pool;
    int m_inFlight = 0;
    /// Set once the host has handed over, before which the store is not read.
    bool m_contextReady = false;
    /// Moves on with every change of selection, so a store read queued for an
    /// account since left can tell, on the pool, that it is not wanted.
    std::atomic<quint64> m_selection{0};
    /// Staged edits a read dropped while their account was off screen, said
    /// once it is back.
    QHash<QString, int> m_dropped;
};
