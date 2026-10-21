# lib/src/upload目录索引

截图上传到 S3 兼容存储。

1. [index.md](index.md)：索引本目录直接子文件和子目录的用途。
2. [s3_upload.dart](s3_upload.dart)：定义上传目标、对象键与链接编码，计算 AWS Signature V4 并以 PUT 上传 PNG。
3. [upload_requests.dart](upload_requests.dart)：处理截图引擎转发到主引擎的上传目标查询与上传请求。
