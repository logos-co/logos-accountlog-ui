#include "AccountLogBackend.h"

#include <QDebug>
#include <QDir>
#include <QJsonArray>
#include <QJsonDocument>
#include <QMetaObject>
#include <QStandardPaths>
#include <QTime>
#include <QtGlobal>

#include "account_core.h"

namespace {

/// Parse a reply and release it. Every library call returns JSON with an `ok`
/// field, so a null or unparseable reply is itself reported as a failed one
/// rather than left to the caller to notice.
QJsonObject takeReply(char *reply)
{
    const QByteArray text(reply);
    logos_account_core_string_free(reply);

    QJsonParseError parse{};
    const QJsonDocument document = QJsonDocument::fromJson(text, &parse);
    if (!document.isObject())
        return QJsonObject{{QStringLiteral("ok"), false},
                           {QStringLiteral("error"), QStringLiteral("unreadable reply: ") + parse.errorString()}};
    return document.object();
}

QByteArray utf8(const QString &text)
{
    return text.toUtf8();
}

/// An empty string from the view means "this account has no password", which
/// the library spells as an absent argument. It cannot mean an empty password:
/// the vault refuses that spelling outright.
const char *passwordArg(const QByteArray &password)
{
    return password.isEmpty() ? nullptr : password.constData();
}

QString compact(const QJsonObject &object)
{
    return QString::fromUtf8(QJsonDocument(object).toJson(QJsonDocument::Compact));
}

/// What a read says about the `count` staged edits it dropped. The log can
/// hold what one adds without holding the edit itself: a key made live under
/// another context, say.
QString droppedText(int count)
{
    return count == 1
        ? QStringLiteral("An edit waiting here adds nothing the store's log does not already "
                         "hold, so it was dropped.")
        : QStringLiteral("%1 edits waiting here add nothing the store's log does not already "
                         "hold, so they were dropped.")
              .arg(count);
}

} // namespace

AccountLogBackend::AccountLogBackend()
{
    m_pool.setMaxThreadCount(1);

    const QString vault = vaultDirectory();
    const QString store = configuredStoreUrl();
    m_core = logos_account_core_new(utf8(vault).constData(), utf8(store).constData());
    setStoreUrl(store);

    if (!m_core) {
        setStatusText(QStringLiteral("Could not read the vault"));
        setVaultProblem(QStringLiteral("the account core could not start on ") + vault);
        return;
    }
    setStatusText(QStringLiteral("Ready"));
    reloadAccounts();
}

AccountLogBackend::~AccountLogBackend()
{
    // The pool holds a raw handle, so it has to drain before the handle goes.
    m_pool.waitForDone();
    logos_account_core_free(m_core);
}

QString AccountLogBackend::vaultDirectory()
{
    const QByteArray override = qgetenv("LOGOS_ACCOUNTLOG_VAULT_DIR");
    if (!override.isEmpty())
        return QString::fromLocal8Bit(override);

    // GenericDataLocation, not AppDataLocation: a view plugin runs inside
    // whichever host spawned it, and AppDataLocation is named after that host.
    // The account keys belong to this app, so the path says so.
    const QString root = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation);
    return QDir(root).filePath(QStringLiteral("logos/accountlog-ui/vault"));
}

QString AccountLogBackend::configuredStoreUrl()
{
    const QByteArray override = qgetenv("LOGOS_ACCOUNTLOG_STORE_URL");
    if (!override.isEmpty())
        return QString::fromLocal8Bit(override);
    return QString::fromUtf8(logos_account_core_default_store_url());
}

void AccountLogBackend::onContextReady()
{
    // Nothing is asked of another module: this app depends on none. The hook is
    // still the first point at which calling out is safe, so the first read of
    // the store happens here rather than in the constructor.
    m_contextReady = true;
    if (m_core && !selectedAddress().isEmpty())
        refresh();
}

void AccountLogBackend::call(const QString &what,
                             std::function<char *(LogosAccountCore *)> work,
                             std::function<void(const QJsonObject &)> landed,
                             std::function<void(const QString &)> refused)
{
    if (!m_core) {
        report(what, QStringLiteral("the account core is not open"));
        return;
    }

    ++m_inFlight;
    setBusy(true);
    LogosAccountCore *core = m_core;
    m_pool.start([this, what, core, work = std::move(work), landed = std::move(landed),
                  refused = std::move(refused)] {
        char *raw = work(core);
        // Back to the thread that owns the properties. A property set from the
        // pool would be a data race with every replica read.
        if (!raw) {
            QMetaObject::invokeMethod(
                this,
                [this] {
                    if (--m_inFlight == 0)
                        setBusy(false);
                },
                Qt::QueuedConnection);
            return;
        }
        const QJsonObject reply = takeReply(raw);
        QMetaObject::invokeMethod(
            this,
            [this, what, reply, landed, refused] {
                if (!reply.value(QStringLiteral("ok")).toBool()) {
                    const QString message = reply.value(QStringLiteral("error")).toString();
                    report(what, message);
                    if (refused)
                        refused(message);
                } else {
                    if (landed)
                        landed(reply);
                    emit succeeded(what);
                }
                // After the handlers, which chain the reads that follow, so
                // busy holds across the chain rather than dropping between its
                // links.
                if (--m_inFlight == 0)
                    setBusy(false);
            },
            Qt::QueuedConnection);
    });
}

void AccountLogBackend::reloadAccounts()
{
    call(QStringLiteral("accounts"),
         [](LogosAccountCore *core) { return logos_account_core_accounts(core); },
         [this](const QJsonObject &reply) {
             setVaultProblem(QString());
             const QJsonArray accounts = reply.value(QStringLiteral("accounts")).toArray();
             setAccountsJson(QString::fromUtf8(QJsonDocument(accounts).toJson(QJsonDocument::Compact)));

             if (accounts.isEmpty()) {
                 setSelection(QString());
                 setStateJson(QStringLiteral("{}"));
                 setStatusText(QStringLiteral("No accounts yet"));
                 return;
             }
             // Hold the selection across a reload; fall to the first account
             // when what was selected is gone, or nothing was.
             const QString held = selectedAddress();
             bool stillHeld = false;
             for (const QJsonValue &account : accounts)
                 stillHeld = stillHeld
                     || account.toObject().value(QStringLiteral("address")).toString() == held;
             if (!stillHeld)
                 setSelection(accounts.first().toObject().value(QStringLiteral("address")).toString());
             reloadState();
             // An account newly on screen has not been read yet this session.
             if (!stillHeld && m_contextReady)
                 refresh();
         },
         // An empty listing would say the vault holds nothing.
         [this](const QString &message) {
             setStatusText(QStringLiteral("Could not read the vault"));
             setVaultProblem(message);
         });
}

void AccountLogBackend::reloadState()
{
    const QByteArray address = utf8(selectedAddress());
    if (address.isEmpty()) {
        setStateJson(QStringLiteral("{}"));
        return;
    }
    call(QStringLiteral("state"),
         [address](LogosAccountCore *core) {
             return logos_account_core_state(core, address.constData());
         },
         [this, address](const QJsonObject &reply) {
             // A reply for an account no longer on screen would put its log
             // under the other one's name.
             if (address != utf8(selectedAddress()))
                 return;
             setVaultProblem(QString());
             setStateJson(compact(reply.value(QStringLiteral("state")).toObject()));
         },
         // Without it the account would show as loading for good.
         [this, address](const QString &message) {
             if (address != utf8(selectedAddress()))
                 return;
             setStatusText(QStringLiteral("Could not read the vault"));
             setVaultProblem(message);
         });
}

void AccountLogBackend::refresh()
{
    const QByteArray address = utf8(selectedAddress());
    if (address.isEmpty()) {
        reloadAccounts();
        return;
    }
    setStatusText(QStringLiteral("Reading the store"));
    const quint64 selection = m_selection.load();
    call(QStringLiteral("refresh"),
         [this, address, selection](LogosAccountCore *core) -> char * {
             // A read queued for an account since left would only hold up the
             // one now on screen, which has its own read queued.
             if (m_selection.load() != selection)
                 return nullptr;
             return logos_account_core_refresh(core, address.constData());
         },
         [this, address, selection](const QJsonObject &reply) {
             // Edits the store already holds leave the pending list, and would
             // go without a word.
             const int dropped = reply.value(QStringLiteral("dropped")).toInt();
             if (dropped > 0 && address == utf8(selectedAddress()))
                 setNotice(QStringLiteral("info"), QStringLiteral("Already in the store"),
                           droppedText(dropped));
             else if (dropped > 0)
                 m_dropped[QString::fromUtf8(address)] += dropped;
             // A read the selection has since moved past speaks for no account
             // on screen, and another read is on its way for the one that is.
             if (m_selection.load() == selection) {
                 setStatusText(QStringLiteral("Ready"));
                 setStoreProblem(QString());
                 setFirstNewIndex(-1);
             }
             reloadAccounts();
         },
         // The vault answers whether or not the store does, and what it holds
         // is what the screen is drawn from.
         [this, selection](const QString &message) {
             if (m_selection.load() == selection) {
                 // Timed, so a retry that fails the same way still shows it ran.
                 setStatusText(QStringLiteral("Could not read the store at %1")
                                   .arg(QTime::currentTime().toString(QStringLiteral("HH:mm:ss"))));
                 setStoreProblem(message);
             }
             reloadAccounts();
         });
}

void AccountLogBackend::selectAccount(QString address)
{
    if (address == selectedAddress())
        return;
    setSelection(address);
    reloadState();
    refresh();
}

void AccountLogBackend::setSelection(const QString &address)
{
    ++m_selection;
    setSelectedAddress(address);
    setFirstNewIndex(-1);
    dismissNotice();
    if (const int dropped = m_dropped.take(address); dropped > 0)
        setNotice(QStringLiteral("info"), QStringLiteral("Already in the store"),
                  droppedText(dropped));
}

void AccountLogBackend::createAccount(QString password)
{
    const QByteArray secret = utf8(password);
    call(QStringLiteral("createAccount"),
         [secret](LogosAccountCore *core) {
             return logos_account_core_create_account(core, passwordArg(secret));
         },
         [this](const QJsonObject &reply) {
             setSelection(reply.value(QStringLiteral("address")).toString());
             reloadAccounts();
             reloadState();
             refresh();
         });
}

void AccountLogBackend::importAccount(QString secretHex, QString password)
{
    const QByteArray secret = utf8(secretHex);
    const QByteArray pass = utf8(password);
    call(QStringLiteral("importAccount"),
         [secret, pass](LogosAccountCore *core) {
             return logos_account_core_import_account(core, secret.constData(), passwordArg(pass));
         },
         [this](const QJsonObject &reply) {
             setSelection(reply.value(QStringLiteral("address")).toString());
             if (reply.value(QStringLiteral("alreadyHeld")).toBool())
                 setNotice(QStringLiteral("info"), QStringLiteral("Already in this vault"),
                           QStringLiteral("This key is an account the vault already holds, so it "
                                          "is kept as it was, with its own password or none."));
             reloadAccounts();
             reloadState();
             refresh();
         });
}

void AccountLogBackend::exportAccount(QString address, QString password)
{
    const QByteArray target = utf8(address);
    const QByteArray pass = utf8(password);
    call(QStringLiteral("exportAccount"),
         [target, pass](LogosAccountCore *core) {
             return logos_account_core_export_account(core, target.constData(), passwordArg(pass));
         },
         [this, address](const QJsonObject &reply) {
             // Straight to the view and nowhere else: not a property, so it is
             // not re-sent to every replica on every later change.
             emit accountExported(address, reply.value(QStringLiteral("key")).toString());
         });
}

void AccountLogBackend::forgetAccount(QString address)
{
    const QByteArray target = utf8(address);
    call(QStringLiteral("forgetAccount"),
         [target](LogosAccountCore *core) {
             return logos_account_core_forget_account(core, target.constData());
         },
         [this, address](const QJsonObject &) {
             m_dropped.remove(address);
             if (address == selectedAddress())
                 setSelection(QString());
             reloadAccounts();
         });
}

void AccountLogBackend::observeAccount(QString address)
{
    // The core takes an address in one spelling only, so what it was asked
    // about is what goes on screen: a selection in any other spelling would
    // never match the state that comes back.
    const QString addr = address.trimmed();
    const QByteArray target = utf8(addr);
    call(QStringLiteral("observeAccount"),
         [target](LogosAccountCore *core) {
             return logos_account_core_observe_account(core, target.constData());
         },
         [this, addr](const QJsonObject &reply) {
             setSelection(addr);
             if (reply.value(QStringLiteral("alreadyObserved")).toBool())
                 setNotice(QStringLiteral("info"), QStringLiteral("Already observed"),
                           QStringLiteral("This account is already one this app reads, so it is "
                                          "shown as it was."));
             reloadAccounts();
             reloadState();
             refresh();
         });
}

void AccountLogBackend::stopObserving(QString address)
{
    const QByteArray target = utf8(address);
    call(QStringLiteral("stopObserving"),
         [target](LogosAccountCore *core) {
             return logos_account_core_stop_observing(core, target.constData());
         },
         [this, address](const QJsonObject &) {
             m_dropped.remove(address);
             if (address == selectedAddress())
                 setSelection(QString());
             reloadAccounts();
         });
}

void AccountLogBackend::stageAddInstallation(QString keyHex)
{
    const QByteArray address = utf8(selectedAddress());
    const QByteArray key = utf8(keyHex.trimmed());
    call(QStringLiteral("stageAddInstallation"),
         [address, key](LogosAccountCore *core) {
             return logos_account_core_stage_add_installation(core, address.constData(),
                                                              key.constData());
         },
         [this](const QJsonObject &) { edited(); });
}

void AccountLogBackend::stageSetDisplayName(QString name)
{
    const QByteArray address = utf8(selectedAddress());
    const QByteArray value = utf8(name);
    call(QStringLiteral("stageSetDisplayName"),
         [address, value](LogosAccountCore *core) {
             return logos_account_core_stage_set_display_name(core, address.constData(),
                                                              value.constData());
         },
         [this](const QJsonObject &) { edited(); });
}

void AccountLogBackend::stageRevoke(int index)
{
    if (index < 0) {
        report(QStringLiteral("stageRevoke"), QStringLiteral("there is no entry before the first"));
        return;
    }
    const QByteArray address = utf8(selectedAddress());
    const quint32 target = static_cast<quint32>(index);
    call(QStringLiteral("stageRevoke"),
         [address, target](LogosAccountCore *core) {
             return logos_account_core_stage_revoke(core, address.constData(), target);
         },
         [this](const QJsonObject &) { edited(); });
}

void AccountLogBackend::discardPending()
{
    const QByteArray address = utf8(selectedAddress());
    call(QStringLiteral("discardPending"),
         [address](LogosAccountCore *core) {
             return logos_account_core_discard_pending(core, address.constData());
         },
         [this](const QJsonObject &) { edited(); });
}

void AccountLogBackend::publish(QString password)
{
    const QString address = selectedAddress();
    const QByteArray target = utf8(address);
    const QByteArray pass = utf8(password);

    setStatusText(QStringLiteral("Publishing"));
    call(QStringLiteral("publish"),
         [target, pass](LogosAccountCore *core) {
             return logos_account_core_publish(core, target.constData(), passwordArg(pass));
         },
         [this, address](const QJsonObject &reply) {
             // Null when the store already held every staged edit.
             const int firstNew = reply.value(QStringLiteral("firstNewIndex")).toInt(-1);
             const int dropped = reply.value(QStringLiteral("dropped")).toInt();
             setStatusText(QStringLiteral("Ready"));
             setStoreProblem(QString());
             // The person may have moved to another account while the store
             // answered, and these describe the one that published.
             if (address != selectedAddress()) {
                 if (dropped > 0)
                     m_dropped[address] += dropped;
             } else if (firstNew < 0) {
                 setNotice(QStringLiteral("info"), QStringLiteral("Already in the store"),
                           droppedText(dropped));
             } else {
                 setFirstNewIndex(firstNew);
                 QString body = QStringLiteral("The store holds this log. Anyone reading this "
                                               "address now sees what was just written.");
                 if (dropped > 0)
                     body += QLatin1Char(' ') + droppedText(dropped);
                 setNotice(QStringLiteral("success"), QStringLiteral("Published"), body);
             }
             if (firstNew >= 0)
                 emit published(address, firstNew);
             reloadAccounts();
         },
         // The sheet the publish came from is still up, and says why.
         [this, address](const QString &) {
             if (address != selectedAddress()) {
                 reloadAccounts();
                 return;
             }
             // The refusal may be the store's, and can follow a read that moved
             // the log on: reading it again says which, and draws what is
             // staged and held.
             refresh();
         });
}

void AccountLogBackend::edited()
{
    // A notice described the log before this edit.
    dismissNotice();
    reloadAccounts();
}

void AccountLogBackend::dismissNotice()
{
    setNotice(QString(), QString(), QString());
}

void AccountLogBackend::setNotice(const QString &kind, const QString &title, const QString &body)
{
    setNoticeKind(kind);
    setNoticeTitle(title);
    setNoticeBody(body);
}

void AccountLogBackend::report(const QString &what, const QString &message)
{
    // A sheet or a screen shows its own call's failure. The two edits made
    // from a button on the log have nowhere else to say it.
    if (what == QLatin1String("stageRevoke")) {
        setNotice(QStringLiteral("error"), QStringLiteral("Could not stage the removal"), message);
    } else if (what == QLatin1String("discardPending")) {
        setNotice(QStringLiteral("error"), QStringLiteral("Could not discard the pending entries"),
                  message);
    }
    qWarning().noquote() << "accountlog_ui:" << what << "failed:" << message;
    emit failed(what, message);
}
