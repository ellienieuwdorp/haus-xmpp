/// Everything pushed onto the Chats stack. Details and encryption are pages to the right of a chat;
/// only the single-device fingerprint review stays modal.
enum ChatRoute: Hashable {
    case chat(String), details(String), encryption(String), groupDetails(String)
}
