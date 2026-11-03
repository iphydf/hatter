#include "platform.h"

#include <QBuffer>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDateTime>
#include <QFileDialog>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QImageReader>
#include <QMimeDatabase>
#include <QPointer>
#include <QQuickItem>
#include <QRandomGenerator>
#include <QRegularExpression>
#include <QSaveFile>
#include <QScreen>
#include <QStandardPaths>
#include <QSysInfo>
#include <QThreadPool>
#include <QUrl>

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <memory>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include "host.h"

namespace {

// Pictures with more pixels aren't decoded, as on Android: one a few
// kilobytes big may say it has billions.
constexpr qint64 mostPixels = qint64(1) << 26;

QString utf8(const char *value)
{
    return QString::fromUtf8(value ? value : "");
}

// A dialog or sheet over the window, gone once it answers.
QObject *ask(const char *kind, std::function<void(int)> then)
{
    // Over the window from the start, as its bindings place it there.
    QObject *popup = host->create(kind, {{QStringLiteral("parent"), QVariant::fromValue(host->window->contentItem())}});
    if (!popup) {
        return nullptr;
    }
    // Gone with the window, if it goes first.
    popup->setParent(host->window);
    ++host->popups;
    auto *answer = new Answer(
        [popup, then = std::move(then)](int action) {
            --host->popups;
            popup->deleteLater();
            then(action);
        },
        popup);
    QObject::connect(popup, SIGNAL(answered(int)), answer, SLOT(answered(int)));
    return popup;
}

// One of the desktop's file dialogs, handing on the files chosen, none if
// the user cancelled. It doesn't wait: the app's call returns first.
QFileDialog *files(std::function<void(const QStringList &)> chosen)
{
    auto *dialog = new QFileDialog;
    dialog->setAttribute(Qt::WA_DeleteOnClose);
    dialog->setWindowModality(Qt::ApplicationModal);
    ++host->popups;
    QObject::connect(dialog, &QFileDialog::finished, dialog, [dialog, chosen = std::move(chosen)](int result) {
        --host->popups;
        chosen(result == QDialog::Accepted ? dialog->selectedFiles() : QStringList());
    });
    return dialog;
}

void open(QObject *popup)
{
    if (popup) {
        QMetaObject::invokeMethod(popup, "open");
    }
}

// The file dialog's filters for a MIME type, like image/* or image/png.
QStringList filters(const QString &mimeType)
{
    if (mimeType.isEmpty() || mimeType == QLatin1String("*/*")) {
        return {};
    }
    const QMimeDatabase mimes;
    QStringList globs;
    if (mimeType.endsWith(QLatin1String("/*"))) {
        const QString kind = mimeType.chopped(1);
        for (const QMimeType &mime : mimes.allMimeTypes()) {
            if (mime.name().startsWith(kind)) {
                globs += mime.globPatterns();
            }
        }
    } else {
        globs = mimes.mimeTypeForName(mimeType).globPatterns();
    }
    globs.removeDuplicates();
    if (globs.isEmpty()) {
        return {};
    }
    return {QStringLiteral("%1 (%2)").arg(mimeType, globs.join(QLatin1Char(' '))), QStringLiteral("* (*)")};
}

QString startIn()
{
    return QStandardPaths::writableLocation(QStandardPaths::PicturesLocation);
}

// A file the user picked, copied where the app may move or delete it, with
// an ASCII name for native code that doesn't know the encoding.
QString copied(const QString &path)
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::CacheLocation) + QStringLiteral("/picked/")
        + QString::number(QDateTime::currentMSecsSinceEpoch()) + QLatin1Char('-')
        + QString::number(QRandomGenerator::global()->generate());
    QDir().mkpath(dir);
    QString name = QFileInfo(path).fileName();
    name.replace(QRegularExpression(QStringLiteral("[^A-Za-z0-9._-]")), QStringLiteral("_"));
    const QString copy = dir + QLatin1Char('/') + name;
    return QFile::copy(path, copy) ? copy : QString();
}

// A picture's reader, turned as its camera says, if it's one of at most
// mostPixels. Its size is before it's turned.
bool reading(QImageReader &reader)
{
    reader.setAutoTransform(true);
    const QSize size = reader.size();
    return size.isValid() && !size.isEmpty() && qint64(size.width()) * size.height() <= mostPixels;
}

// A picked picture cut to its middle square and scaled to the first of
// the sides whose PNG has at most limit bytes.
QByteArray square(const QString &path, const std::vector<int> &sides, int limit)
{
    QImageReader reader(path);
    if (!reading(reader)) {
        return {};
    }
    const QImage picture = reader.read();
    if (picture.isNull()) {
        return {};
    }
    const int side = std::min(picture.width(), picture.height());
    const QImage middle = picture.copy((picture.width() - side) / 2, (picture.height() - side) / 2, side, side);
    for (int wanted : sides) {
        QByteArray png;
        QBuffer buffer(&png);
        buffer.open(QIODevice::WriteOnly);
        middle.scaled(wanted, wanted, Qt::IgnoreAspectRatio, Qt::SmoothTransformation).save(&buffer, "PNG");
        if (png.size() <= limit) {
            return png;
        }
    }
    return {};
}

} // namespace

namespace {

const QString notifier = QStringLiteral("org.freedesktop.Notifications");
const QString notifierPath = QStringLiteral("/org/freedesktop/Notifications");

// Hatter's NotificationBridge.h.
enum { RingingCall = 1, MissedCall = 2 };

} // namespace

Notifications::Notifications()
{
    QDBusConnection bus = QDBusConnection::sessionBus();
    bus.connect(notifier, notifierPath, notifier, QStringLiteral("ActionInvoked"), this, SLOT(invoked(uint, QString)));
    bus.connect(notifier, notifierPath, notifier, QStringLiteral("NotificationClosed"), this, SLOT(closed(uint, uint)));
}

// In place of the one with the same key. A ringing call stays until it's
// answered or cancelled.
void Notifications::show(const QString &key, const QString &title, const QString &text, int kind)
{
    QDBusMessage notify = QDBusMessage::createMethodCall(notifier, notifierPath, notifier, QStringLiteral("Notify"));
    const QVariantMap hints{
        {QStringLiteral("category"), kind == RingingCall ? QStringLiteral("call.incoming")
                                     : kind == MissedCall ? QStringLiteral("call.unanswered")
                                                          : QStringLiteral("im.received")},
        {QStringLiteral("urgency"), QVariant::fromValue<uchar>(kind == RingingCall ? 2 : 1)},
    };
    notify << QGuiApplication::applicationDisplayName() << ids.value(key) << QString() << title
           << notificationBody(text)
           << QStringList{QStringLiteral("default"), QStringLiteral("Open")} << hints
           << (kind == RingingCall ? 0 : -1);
    auto *watcher = new QDBusPendingCallWatcher(QDBusConnection::sessionBus().asyncCall(notify), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, key](QDBusPendingCallWatcher *call) {
        const QDBusPendingReply<uint> reply = *call;
        if (reply.isValid()) {
            ids.insert(key, reply.value());
        }
        call->deleteLater();
    });
}

void Notifications::cancel(const QString &key)
{
    const uint id = ids.take(key);
    if (id) {
        QDBusMessage close =
            QDBusMessage::createMethodCall(notifier, notifierPath, notifier, QStringLiteral("CloseNotification"));
        close << id;
        QDBusConnection::sessionBus().asyncCall(close);
    }
}

void Notifications::invoked(uint id, const QString &)
{
    const QString key = ids.key(id);
    if (key.isEmpty()) {
        return;
    }
    host->window->show();
    host->window->raise();
    host->window->requestActivate();
    host->app.notified(host->app.ctx, key.toUtf8().constData());
}

void Notifications::closed(uint id, uint)
{
    ids.remove(ids.key(id));
}

QString notificationBody(const QString &text)
{
    return text.toHtmlEscaped();
}

void copyPicked(const QStringList &paths, std::function<void(const QString &, const QString &, qint64)> each)
{
    QThreadPool::globalInstance()->start([paths, each = std::move(each)] {
        for (const QString &path : paths) {
            const QString copy = copied(path);
            if (!copy.isEmpty()) {
                QMetaObject::invokeMethod(qApp, [each, copy, name = QFileInfo(path).fileName(),
                                                 size = QFileInfo(copy).size()] { each(copy, name, size); });
            }
        }
    });
}

bool replaceWith(const QString &source, const QString &target)
{
    QFile in(source);
    QSaveFile out(target);
    if (!in.open(QIODevice::ReadOnly) || !out.open(QIODevice::WriteOnly)) {
        return false;
    }
    // As private as what the app saved, as a copy would be.
    out.setPermissions(in.permissions());
    char buffer[64 * 1024];
    qint64 n;
    while ((n = in.read(buffer, sizeof buffer)) > 0) {
        if (out.write(buffer, n) != n) {
            return false;
        }
    }
    return n == 0 && out.commit();
}

void pickFiles(const QString &mimeType, bool several)
{
    QFileDialog *dialog = files([](const QStringList &chosen) {
        copyPicked(chosen, [](const QString &copy, const QString &name, qint64 size) {
            host->app.picked(host->app.ctx, copy.toUtf8().constData(), name.toUtf8().constData(), size);
        });
    });
    dialog->setFileMode(several ? QFileDialog::ExistingFiles : QFileDialog::ExistingFile);
    dialog->setNameFilters(filters(mimeType));
    dialog->setDirectory(startIn());
    dialog->open();
}

void capturePicture()
{
    const QString folder = QStandardPaths::writableLocation(QStandardPaths::CacheLocation) + QStringLiteral("/captured");
    QDir().mkpath(folder);
    // The camera's popup, for its answer to read what it took.
    auto taking = std::make_shared<QPointer<QObject>>();
    *taking = ask("Camera", [taking](int took) {
        const QFileInfo taken((*taking) ? (*taking)->property("taken").toString() : QString());
        if (took && taken.size() > 0) {
            host->app.picked(host->app.ctx, taken.filePath().toUtf8().constData(),
                             taken.fileName().toUtf8().constData(), taken.size());
        }
    });
    if (*taking) {
        (*taking)->setProperty("folder", folder);
        open(*taking);
    }
}

void pickPicture(const std::vector<int> &sides, int limit)
{
    QFileDialog *dialog = files([sides, limit](const QStringList &chosen) {
        const QByteArray png = chosen.isEmpty() ? QByteArray() : square(chosen.first(), sides, limit);
        if (!png.isEmpty()) {
            host->app.picture(host->app.ctx, reinterpret_cast<const uint8_t *>(png.constData()), int32_t(png.size()));
        }
    });
    dialog->setFileMode(QFileDialog::ExistingFile);
    dialog->setNameFilters(filters(QStringLiteral("image/*")));
    dialog->setDirectory(startIn());
    dialog->open();
}

// Off the window's thread, as it may be large. The app's file is deleted
// afterwards, saved or not, and the user told which, as on Android.
void saveFile(const QString &path, const QString &name)
{
    QFileDialog *dialog = files([path](const QStringList &chosen) {
        QThreadPool::globalInstance()->start([path, target = chosen.value(0)] {
            const bool saved = !target.isEmpty() && replaceWith(path, target);
            QFile::remove(path);
            if (!target.isEmpty()) {
                QMetaObject::invokeMethod(qApp, [saved] {
                    host->toast(saved ? QStringLiteral("Saved") : QStringLiteral("Couldn't save"));
                });
            }
        });
    });
    dialog->setAcceptMode(QFileDialog::AcceptSave);
    dialog->setDirectory(QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation));
    dialog->selectFile(name);
    dialog->open();
}

bool imageSize(const QString &path, int *width, int *height)
{
    QImageReader reader(path);
    reader.setAutoTransform(true);
    QSize size = reader.size();
    if (!size.isValid() || size.isEmpty()) {
        return false;
    }
    if (reader.transformation() & QImageIOHandler::TransformationRotate90) {
        size.transpose();
    }
    *width = size.width();
    *height = size.height();
    return true;
}

namespace {

// The screen's longest side in pixels, 0 if there's no screen.
int screenLongest()
{
    const QScreen *screen = QGuiApplication::primaryScreen();
    return screen ? int(std::max(screen->size().width(), screen->size().height()) * screen->devicePixelRatio()) : 0;
}

} // namespace

QSize shownSize(const QString &path)
{
    const int longest = screenLongest();
    int width = 0, height = 0;
    // Its longest side only: given both, Qt fills both.
    if (longest > 0 && imageSize(path, &width, &height) && std::max(width, height) > longest) {
        return width >= height ? QSize(longest, 0) : QSize(0, longest);
    }
    return {};
}

QImage shownPicture(const QByteArray &bytes)
{
    QBuffer buffer;
    buffer.setData(bytes);
    QImageReader reader(&buffer);
    if (!reading(reader)) {
        return {};
    }
    const int longest = screenLongest();
    const QSize size = reader.size();
    if (longest > 0 && std::max(size.width(), size.height()) > longest) {
        reader.setScaledSize(size.scaled(longest, longest, Qt::KeepAspectRatio));
    }
    return reader.read();
}

namespace {

// A new key on the disk before it has its name, as what it encrypts is kept
// as soon as it's made: else a crash may leave the name with nothing. Only
// the user can read it, never others meanwhile.
bool keepKey(const QByteArray &dir, const QByteArray &path)
{
    const QByteArray made = path + '.' + QByteArray::number(::getpid());
    // Left by a start that crashed.
    ::unlink(made.constData());
    const int fd = ::open(made.constData(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR);
    if (fd < 0) {
        return false;
    }
    uint8_t key[32];
    QRandomGenerator::system()->fillRange(reinterpret_cast<quint32 *>(key), sizeof key / sizeof(quint32));
    const bool written = ::write(fd, key, sizeof key) == ssize_t(sizeof key) && ::fsync(fd) == 0;
    ::close(fd);
    // Only if no other start made one meanwhile, whose key may be in use.
    const bool named = written
        && (::link(made.constData(), path.constData()) == 0 || errno == EEXIST
            || ::rename(made.constData(), path.constData()) == 0);
    ::unlink(made.constData());
    const int dirFd = ::open(dir.constData(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    const bool synced = dirFd >= 0 && ::fsync(dirFd) == 0;
    if (dirFd >= 0) {
        ::close(dirFd);
    }
    return named && synced;
}

} // namespace

extern "C" {

void hatter_qt_dialog(void *, int32_t requestId, const char *title, const char *message, const char *button1,
                      const char *button2, const char *button3)
{
    QObject *dialog = ask("Dialog", [requestId](int action) { host->app.dialog(host->app.ctx, requestId, action); });
    if (dialog) {
        dialog->setProperty("title", utf8(title));
        dialog->setProperty("message", utf8(message));
        dialog->setProperty("button1", utf8(button1));
        dialog->setProperty("button2", utf8(button2));
        dialog->setProperty("button3", utf8(button3));
        open(dialog);
    }
}

void hatter_qt_sheet(void *, int32_t requestId, const char *title, const char *items)
{
    QObject *sheet = ask("Sheet", [requestId](int action) { host->app.sheet(host->app.ctx, requestId, action); });
    if (sheet) {
        sheet->setProperty("title", utf8(title));
        sheet->setProperty("items", utf8(items).split(QLatin1Char('\n')));
        open(sheet);
    }
}

uint8_t *hatter_qt_picture_pixels(const char *path, int32_t most, int32_t *width, int32_t *height)
{
    QImageReader reader(utf8(path));
    if (!reading(reader)) {
        return nullptr;
    }
    // Halved until there are at most so many, decoded small if the format can.
    QSize size = reader.size();
    while (qint64(size.width()) * size.height() > most && size.width() > 1 && size.height() > 1) {
        size /= 2;
    }
    reader.setScaledSize(size);
    const QImage picture = reader.read().convertToFormat(QImage::Format_RGBA8888);
    if (picture.isNull()) {
        return nullptr;
    }
    const qsizetype row = qsizetype(picture.width()) * 4;
    auto *pixels = static_cast<uint8_t *>(malloc(row * picture.height()));
    if (!pixels) {
        return nullptr;
    }
    for (int y = 0; y < picture.height(); ++y) {
        memcpy(pixels + row * y, picture.constScanLine(y), row);
    }
    *width = picture.width();
    *height = picture.height();
    return pixels;
}

int32_t hatter_qt_picture_shrink(const char *path, const char *out, int32_t longest)
{
    QImageReader reader(utf8(path));
    if (!reading(reader)) {
        return 0;
    }
    QImage picture = reader.read();
    if (picture.isNull()) {
        return 0;
    }
    if (std::max(picture.width(), picture.height()) > longest) {
        picture = picture.scaled(longest, longest, Qt::KeepAspectRatio, Qt::SmoothTransformation);
    }
    // Written again, without the original's metadata.
    const bool clear = picture.hasAlphaChannel();
    if (!picture.save(utf8(out), clear ? "PNG" : "JPEG", clear ? -1 : 85)) {
        QFile::remove(utf8(out));
        return 0;
    }
    return clear ? 2 : 1;
}

int hatter_qt_database_key(uint8_t key[32])
{
    const QString dir = QString::fromUtf8(hatter_qt_files_dir());
    QFile file(dir + QStringLiteral("/database.key"));
    if (!file.exists() && !keepKey(QFile::encodeName(dir), QFile::encodeName(file.fileName()))) {
        return 0;
    }
    if (!file.open(QIODevice::ReadOnly)) {
        return 0;
    }
    const QByteArray kept = file.readAll();
    if (kept.size() != 32) {
        return 0;
    }
    memcpy(key, kept.constData(), 32);
    return 1;
}

// From any thread: the desktop's notifications are the UI thread's.
void hatter_qt_notify(const char *key, const char *, const char *, const char *title, const char *text, int kind)
{
    QMetaObject::invokeMethod(qApp, [key = utf8(key), title = utf8(title), text = utf8(text), kind] {
        host->notifications->show(key, title, text, kind);
    });
}

void hatter_qt_unnotify(const char *key)
{
    QMetaObject::invokeMethod(qApp, [key = utf8(key)] { host->notifications->cancel(key); });
}

HatterQtDevice hatter_qt_device(void)
{
    static const QByteArray model = QSysInfo::prettyProductName().toUtf8();
    static const QByteArray version = QSysInfo::productVersion().toUtf8();
    // Qt's lengths are already independent of the screen's density.
    return {model.constData(), version.constData(), "1", "400", "760", host->graphics.constData()};
}

} // extern "C"
