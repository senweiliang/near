part of '../home_page.dart';

// ===================================================================
// Compose
// ===================================================================

class _PasteOverrideAction extends Action<PasteTextIntent> {
  _PasteOverrideAction(this.onPaste);
  final Future<void> Function() onPaste;

  @override
  Object? invoke(PasteTextIntent intent) {
    onPaste();
    return null;
  }
}

class _Compose extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final String recipientLabel;
  final String placeholder;
  final VoidCallback onSend;
  final VoidCallback onPickImage;
  final void Function(BuildContext buttonContext) onPickFile;
  final Future<void> Function() onPaste;
  const _Compose({
    required this.controller,
    this.focusNode,
    required this.recipientLabel,
    required this.placeholder,
    required this.onSend,
    required this.onPickImage,
    required this.onPickFile,
    required this.onPaste,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bgApp,
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
                child: Row(
                  children: [
                    Text(
                      'To ',
                      style:
                          AppFonts.body(size: 12, color: AppColors.ink3),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 9, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.accentSoft,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        recipientLabel,
                        style: AppFonts.body(
                          size: 11.5,
                          weight: FontWeight.w600,
                          color: AppColors.accentDeep,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: onPickImage,
                      customBorder: const CircleBorder(),
                      child: const SizedBox(
                        width: 44,
                        height: 44,
                        child: Center(
                          child: Icon(Icons.image_outlined,
                              color: AppColors.ink2, size: 22),
                        ),
                      ),
                    ),
                  ),
                  Material(
                    color: Colors.transparent,
                    child: Builder(builder: (buttonContext) => InkWell(
                      onTap: () => onPickFile(buttonContext),
                      customBorder: const CircleBorder(),
                      child: const SizedBox(
                        width: 44,
                        height: 44,
                        child: Center(
                          child: Icon(Icons.attach_file_rounded,
                              color: AppColors.ink2, size: 22),
                        ),
                      ),
                    )),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 44),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          border: Border.all(color: AppColors.line),
                          borderRadius: BorderRadius.circular(22),
                        ),
                        child: Actions(
                          actions: <Type, Action<Intent>>{
                            PasteTextIntent: _PasteOverrideAction(onPaste),
                          },
                          child: TextField(
                            controller: controller,
                            focusNode: focusNode,
                            minLines: 1,
                            maxLines: 5,
                            style: AppFonts.body(
                                size: 15,
                                color: AppColors.ink,
                                height: 1.4),
                            decoration: InputDecoration(
                              isCollapsed: true,
                              border: InputBorder.none,
                              hintText: placeholder,
                              hintStyle: AppFonts.body(
                                  size: 15, color: AppColors.ink3),
                            ),
                            onSubmitted: (_) => onSend(),
                            textInputAction: TextInputAction.send,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: onSend,
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: const BoxDecoration(
                        color: AppColors.accent,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: const Icon(Icons.send,
                          color: Colors.white, size: 18),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

